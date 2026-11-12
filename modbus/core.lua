--[[
@module  core
@summary Modbus RTU 协议处理引擎（主站/从站通用，纯函数）
@version 1.0
@date    2026.11.05
@usage
本文件是一套与硬件完全无关的 Modbus RTU 编解码引擎：
- 不依赖 uart、不启动 task、不持有任何全局可变状态
- 主站（下行读设备）与从站（上行应平台）共用同一套函数
- 只做「字节串 → 结构体」和「结构体 → 字节串」的纯变换

共用部分：
  crc16 / adu_add_crc / adu_check_crc
  pack_u16 / unpack_u16 / pack_u32 / unpack_u32
  异常码常量 EXCEPTION_xxx

主站侧（发请求、收响应）：
  encode_request(opts)   → adu 字符串
  decode_response(adu, req_fc) → 解析结果

从站侧（收请求、发响应）：
  decode_request(adu)    → 解析结果
  encode_response(opts)  → adu 字符串

异常帧：
  encode_exception(dev_id, fc, code) → adu
  decode_exception(adu)              → {dev_id, fc, code}

内部错误码（0xC8~0xCD，仅作为函数返回值，永不上总线，与标准异常码 0x01~0x0B 区分）：
  0xC8 帧长度不足   0xC9 CRC 校验失败   0xCA 功能码不匹配
  0xCB 字节数不匹配  0xCC 参数非法       0xCD 不支持的异常码

术语：
  PDU = 功能码 + 数据域（无地址、无 CRC）
  ADU = 从站地址 + PDU + CRC16
]]

local _M = {}

-- ============================================================
-- 内部错误码（帧层错误，0xC8~0xCD，仅作返回值，不会出现在总线上）
-- ============================================================
_M.ERR_FRAME_SHORT      = 0xC8   -- 帧长度不足
_M.ERR_CRC              = 0xC9   -- CRC 校验失败
_M.ERR_FC_MISMATCH      = 0xCA   -- 功能码不匹配
_M.ERR_BYTECOUNT        = 0xCB   -- 字节数不匹配
_M.ERR_PARAM            = 0xCC   -- 参数非法
_M.ERR_EXCEPTION_CODE   = 0xCD   -- 不支持的异常码

-- ============================================================
-- Modbus 标准异常码（正数，会出现在异常响应帧里）
-- ============================================================
_M.EXCEPTION_ILLEGAL_FUNCTION        = 0x01  -- 非法功能码
_M.EXCEPTION_ILLEGAL_DATA_ADDRESS    = 0x02  -- 非法数据地址
_M.EXCEPTION_ILLEGAL_DATA_VALUE      = 0x03  -- 非法数据值
_M.EXCEPTION_SLAVE_DEVICE_FAILURE    = 0x04  -- 从站设备故障
_M.EXCEPTION_ACKNOWLEDGE             = 0x05  -- 确认（执行中）
_M.EXCEPTION_SLAVE_DEVICE_BUSY       = 0x06  -- 从站设备忙
_M.EXCEPTION_NEGATIVE_ACKNOWLEDGE    = 0x07  -- 否定确认
_M.EXCEPTION_MEMORY_PARITY_ERROR     = 0x08  -- 存储奇偶校验错
_M.EXCEPTION_GATEWAY_PATH_UNAVAILABLE = 0x0A -- 网关路径不可用
_M.EXCEPTION_GATEWAY_TARGET_FAILED   = 0x0B  -- 网关目标设备响应失败

-- ============================================================
-- 功能码常量
-- ============================================================
-- 0x01 读线圈（Read Coils）
--   读取输出线圈（可读可写的开关量）当前状态，单位是 1 bit
--   传统地址区：0xxxx（00001~09999）
--   响应数据：按位打包，低位在前，1 = ON / 0 = OFF
_M.FC_READ_COILS               = 0x01

-- 0x02 读离散输入（Read Discrete Inputs）
--   读取只读的开关量输入（如故障干接点、限位开关），单位是 1 bit
--   传统地址区：1xxxx（10001~19999）
--   响应数据：与 0x01 相同的按位打包方式
_M.FC_READ_DISCRETE_INPUTS     = 0x02

-- 0x03 读保持寄存器（Read Holding Registers）
--   读取可读可写的 16bit 寄存器（参数、设定值、累计量等）
--   传统地址区：4xxxx（40001~49999）
--   响应数据：每 2 字节一个寄存器，大端序
_M.FC_READ_HOLDING_REGISTERS   = 0x03

-- 0x04 读输入寄存器（Read Input Registers）
--   读取只读的 16bit 寄存器（实时测量值：电压、电流、温度等）
--   传统地址区：3xxxx（30001~39999）
--   响应数据：与 0x03 相同的排列方式，只是语义上只读
_M.FC_READ_INPUT_REGISTERS     = 0x04

-- 0x05 写单个线圈（Write Single Coil）
--   控制单个输出线圈通断，单位是 1 bit
--   数据域：0xFF00 = 置位（ON），0x0000 = 复位（OFF），其他值非法
--   响应：原样回显请求的地址和值
_M.FC_WRITE_SINGLE_COIL        = 0x05

-- 0x06 写单个寄存器（Write Single Register）
--   写入单个 16bit 保持寄存器，常用于改设定值、下发控制命令
--   数据域：任意 0x0000~0xFFFF
--   响应：原样回显请求的地址和值
_M.FC_WRITE_SINGLE_REGISTER    = 0x06

-- 0x0F 写多个线圈（Write Multiple Coils）
--   批量控制连续的一段输出线圈，单次最多 1968 个位（246 字节）
--   请求数据域：起始地址 + 数量 + 字节数 + 按位打包的数据
--   响应：只回显起始地址和数量，不回显数据
_M.FC_WRITE_MULTIPLE_COILS     = 0x0F

-- 0x10 写多个寄存器（Write Multiple Registers）
--   批量写入连续的一段保持寄存器，单次最多 123 个寄存器（246 字节）
--   请求数据域：起始地址 + 数量 + 字节数 + 每 2 字节一个值
--   响应：只回显起始地址和数量，不回显数据
_M.FC_WRITE_MULTIPLE_REGISTERS = 0x10

-- ============================================================
-- 数量上限（Modbus 规范定义）
-- ============================================================
_M.MAX_READ_BITS     = 2000   -- 01/02 一次最多读 2000 个位
_M.MAX_READ_REGS     = 125    -- 03/04 一次最多读 125 个寄存器
_M.MAX_WRITE_BITS    = 1968   -- 0F 一次最多写 1968 个位
_M.MAX_WRITE_REGS    = 123    -- 10 一次最多写 123 个寄存器

-- ============================================================
-- 工具：判断功能码是否属于「按位操作」
-- ============================================================
local function is_bit_fc(fc)
    return fc == 0x01 or fc == 0x02 or fc == 0x05 or fc == 0x0F
end

-- ============================================================
-- 工具：判断功能码是否属于「读操作」
-- ============================================================
local function is_read_fc(fc)
    return fc == 0x01 or fc == 0x02 or fc == 0x03 or fc == 0x04
end

_M.is_bit_fc  = is_bit_fc
_M.is_read_fc = is_read_fc

-- ============================================================
-- CRC16（Modbus 标准：多项式 0xA001，初值 0xFFFF）
-- 入参：PDU 字节串；返回：16bit 整数
-- ============================================================
function _M.crc16(data)
    if type(data) ~= "string" or #data == 0 then
        return 0
    end
    local crc = 0xFFFF
    for i = 1, #data do
        crc = crc ~ data:byte(i)
        for _ = 1, 8 do
            if (crc & 0x0001) ~= 0 then
                crc = (crc >> 1) ~ 0xA001
            else
                crc = crc >> 1
            end
        end
    end
    return crc
end

-- ============================================================
-- 给 PDU 追加 CRC，得到完整 ADU
-- 入参：PDU（从站地址 + 功能码 + 数据域）
-- 返回：ADU（PDU + CRC 低字节 + CRC 高字节）
-- ============================================================
function _M.adu_add_crc(pdu)
    local crc = _M.crc16(pdu)
    return pdu .. string.char(crc & 0xFF, (crc >> 8) & 0xFF)
end

-- ============================================================
-- 校验 ADU 的 CRC
-- 入参：完整 ADU（含 CRC 两字节）
-- 返回：true 校验通过 / false 校验失败
-- ============================================================
function _M.adu_check_crc(adu)
    if type(adu) ~= "string" or #adu < 4 then
        return false
    end
    local payload = adu:sub(1, -3)
    local crc_recv = adu:byte(-2) | (adu:byte(-1) << 8)
    return crc_recv == _M.crc16(payload)
end

-- ============================================================
-- 取掉 ADU 尾部的 CRC，得到 PDU
-- ============================================================
function _M.adu_strip_crc(adu)
    if type(adu) ~= "string" or #adu < 4 then
        return nil
    end
    return adu:sub(1, -3)
end

-- ============================================================
-- 字节打包 / 解包（大端序，高字节在前）
-- ============================================================
function _M.pack_u16(value)
    value = math.floor(value or 0)
    return string.char((value >> 8) & 0xFF, value & 0xFF)
end

-- 从 s 的第 pos 个字节开始解析 2 字节无符号整数（pos 从 1 开始）
function _M.unpack_u16(s, pos)
    pos = pos or 1
    if type(s) ~= "string" or #s < pos + 1 then
        return nil
    end
    return s:byte(pos) * 0x100 + s:byte(pos + 1)
end

function _M.pack_u32(value)
    -- 用除法取字节，避免 32bit 整数左移溢出（与本项目其他模块保持一致）
    value = math.floor(value or 0)
    local b1 = math.floor(value / 0x1000000) % 0x100
    local b2 = math.floor(value / 0x10000) % 0x100
    local b3 = math.floor(value / 0x100) % 0x100
    local b4 = value % 0x100
    return string.char(b1, b2, b3, b4)
end

function _M.unpack_u32(s, pos)
    pos = pos or 1
    if type(s) ~= "string" or #s < pos + 3 then
        return nil
    end
    return s:byte(pos) * 0x1000000
         + s:byte(pos + 1) * 0x10000
         + s:byte(pos + 2) * 0x100
         + s:byte(pos + 3)
end

-- ============================================================
-- 组帧：请求（主站用）
-- opts = {
--   dev_id = 1,              -- 从站地址 1~247
--   fc     = 0x03,           -- 功能码
--   addr   = 3000,           -- 起始地址（或写入地址）
--   qty    = 2,              -- 读数量 / 写多个的数量
--   value  = 100,            -- 05/06 写单值时用
--   values = {1,2,3},        -- 0F/10 写多值时用（按位功能码时为 0/1 数组）
-- }
-- 返回：adu 字符串；参数非法返回 nil
-- ============================================================
function _M.encode_request(opts)
    if type(opts) ~= "table" or not opts.dev_id or not opts.fc or opts.addr == nil then
        return nil
    end
    local dev_id = math.floor(opts.dev_id) & 0xFF
    local fc     = math.floor(opts.fc) & 0xFF
    local addr   = math.floor(opts.addr) & 0xFFFF

    local pdu
    if is_read_fc(fc) then
        local qty = math.floor(opts.qty or 0)
        if qty < 1 or qty > (is_bit_fc(fc) and _M.MAX_READ_BITS or _M.MAX_READ_REGS) then
            return nil
        end
        pdu = string.char(dev_id, fc) .. _M.pack_u16(addr) .. _M.pack_u16(qty)

    elseif fc == 0x05 or fc == 0x06 then
        local value = math.floor(opts.value or 0)
        if fc == 0x05 then
            -- 写单个线圈：0xFF00 = 置位，0x0000 = 复位
            value = (value ~= 0) and 0xFF00 or 0x0000
        else
            value = value & 0xFFFF
        end
        pdu = string.char(dev_id, fc) .. _M.pack_u16(addr) .. _M.pack_u16(value)

    elseif fc == 0x0F or fc == 0x10 then
        local values = opts.values
        if type(values) ~= "table" or #values == 0 then
            return nil
        end
        local qty = math.floor(opts.qty or #values)
        if qty < 1 or qty > (is_bit_fc(fc) and _M.MAX_WRITE_BITS or _M.MAX_WRITE_REGS) then
            return nil
        end

        local data
        if fc == 0x0F then
            -- 写多个线圈：按位打包，第 1 个值放 bit0，低位在前
            local byte_count = math.floor((qty + 7) / 8)
            local bytes = {}
            for i = 1, byte_count do bytes[i] = 0 end
            for i = 1, qty do
                if values[i] and values[i] ~= 0 then
                    local bit = (i - 1) % 8
                    bytes[math.floor((i - 1) / 8) + 1] = bytes[math.floor((i - 1) / 8) + 1] | (1 << bit)
                end
            end
            data = _M.pack_u16(qty) .. string.char(byte_count) .. string.char(table.unpack(bytes))
        else
            -- 写多个寄存器：数量 2 字节 + 字节数 1 字节 + 每个值 2 字节
            local parts = { _M.pack_u16(qty), string.char(qty * 2) }
            for i = 1, qty do
                parts[#parts + 1] = _M.pack_u16(values[i] or 0)
            end
            data = table.concat(parts)
        end
        pdu = string.char(dev_id, fc) .. _M.pack_u16(addr) .. data

    else
        return nil
    end

    return _M.adu_add_crc(pdu)
end

-- ============================================================
-- 解帧：请求（从站用）
-- 入参：完整 ADU
-- 返回：{ dev_id, fc, addr, qty, value, values, broadcast } 或 nil, 错误码
-- ============================================================
function _M.decode_request(adu)
    if type(adu) ~= "string" or #adu < 4 then
        return nil, _M.ERR_FRAME_SHORT
    end
    if not _M.adu_check_crc(adu) then
        return nil, _M.ERR_CRC
    end

    local dev_id = adu:byte(1)
    local fc     = adu:byte(2)

    -- 异常响应帧不是请求
    if (fc & 0x80) ~= 0 then
        return nil, _M.ERR_FC_MISMATCH
    end

    local req = { dev_id = dev_id, fc = fc, broadcast = (dev_id == 0) }

    if is_read_fc(fc) then
        if #adu < 8 then return nil, _M.ERR_FRAME_SHORT end
        req.addr = _M.unpack_u16(adu, 3)
        req.qty  = _M.unpack_u16(adu, 5)
        if req.qty < 1 or req.qty > (is_bit_fc(fc) and _M.MAX_READ_BITS or _M.MAX_READ_REGS) then
            return nil, _M.ERR_PARAM
        end

    elseif fc == 0x05 or fc == 0x06 then
        if #adu < 8 then return nil, _M.ERR_FRAME_SHORT end
        req.addr  = _M.unpack_u16(adu, 3)
        req.value = _M.unpack_u16(adu, 5)
        if fc == 0x05 and req.value ~= 0xFF00 and req.value ~= 0x0000 then
            return nil, _M.ERR_PARAM
        end

    elseif fc == 0x0F or fc == 0x10 then
        if #adu < 9 then return nil, _M.ERR_FRAME_SHORT end
        req.addr       = _M.unpack_u16(adu, 3)
        req.qty        = _M.unpack_u16(adu, 5)
        req.byte_count = adu:byte(7)
        if req.qty < 1 or req.qty > (is_bit_fc(fc) and _M.MAX_WRITE_BITS or _M.MAX_WRITE_REGS) then
            return nil, _M.ERR_PARAM
        end
        local expect = (fc == 0x0F) and math.floor((req.qty + 7) / 8) or (req.qty * 2)
        if req.byte_count ~= expect then
            return nil, _M.ERR_BYTECOUNT
        end
        if #adu < 7 + req.byte_count + 2 then
            return nil, _M.ERR_FRAME_SHORT
        end

        req.values = {}
        if fc == 0x0F then
            for i = 1, req.qty do
                local byte_idx = math.floor((i - 1) / 8) + 1
                local bit = (i - 1) % 8
                req.values[i] = (adu:byte(7 + byte_idx) >> bit) & 0x01
            end
        else
            for i = 1, req.qty do
                req.values[i] = _M.unpack_u16(adu, 7 + (i - 1) * 2 + 1)
            end
        end

    else
        return nil, _M.ERR_PARAM
    end

    return req
end

-- ============================================================
-- 解帧：响应（主站用）
-- 入参：adu、本次请求的功能码（可选，传了就校验一致性）
-- 返回：{
--   dev_id, fc,             -- fc 已去掉 0x80 标志位
--   is_exception, exception_code,
--   byte_count, bytes,      -- 读响应：原始字节数组（1-based）
--   values,                 -- 读响应：按位功能码已解出 0/1 数组
--   addr, qty, value        -- 写响应：回显字段
-- } 或 nil, 错误码
-- ============================================================
function _M.decode_response(adu, req_fc)
    if type(adu) ~= "string" or #adu < 4 then
        return nil, _M.ERR_FRAME_SHORT
    end
    if not _M.adu_check_crc(adu) then
        return nil, _M.ERR_CRC
    end

    local dev_id = adu:byte(1)
    local fc_raw = adu:byte(2)
    local fc     = fc_raw & 0x7F

    local resp = { dev_id = dev_id, fc = fc, is_exception = false }

    -- 异常响应：功能码最高位置 1，第 3 字节是异常码
    if (fc_raw & 0x80) ~= 0 then
        if #adu < 5 then return nil, _M.ERR_FRAME_SHORT end
        resp.is_exception   = true
        resp.exception_code = adu:byte(3)
        if resp.exception_code < 1 or resp.exception_code > 0x0B then
            return nil, _M.ERR_EXCEPTION_CODE
        end
        if req_fc and fc ~= req_fc then
            return nil, _M.ERR_FC_MISMATCH
        end
        return resp
    end

    if req_fc and fc ~= req_fc then
        return nil, _M.ERR_FC_MISMATCH
    end

    if is_read_fc(fc) then
        if #adu < 5 then return nil, _M.ERR_FRAME_SHORT end
        resp.byte_count = adu:byte(3)
        if #adu < 3 + resp.byte_count + 2 then
            return nil, _M.ERR_BYTECOUNT
        end
        resp.bytes = {}
        for i = 1, resp.byte_count do
            resp.bytes[i] = adu:byte(3 + i)
        end
        if is_bit_fc(fc) then
            -- 按位功能码：逐 bit 解出 0/1
            resp.values = {}
            local bit_index = 1
            for i = 1, resp.byte_count do
                for b = 0, 7 do
                    resp.values[bit_index] = (resp.bytes[i] >> b) & 0x01
                    bit_index = bit_index + 1
                end
            end
        else
            -- 寄存器功能码：每 2 字节一个 16bit 值
            resp.values = {}
            for i = 1, math.floor(resp.byte_count / 2) do
                resp.values[i] = _M.unpack_u16(adu, 3 + (i - 1) * 2 + 1)
            end
        end

    elseif fc == 0x05 or fc == 0x06 then
        if #adu < 8 then return nil, _M.ERR_FRAME_SHORT end
        resp.addr  = _M.unpack_u16(adu, 3)
        resp.value = _M.unpack_u16(adu, 5)

    elseif fc == 0x0F or fc == 0x10 then
        if #adu < 8 then return nil, _M.ERR_FRAME_SHORT end
        resp.addr = _M.unpack_u16(adu, 3)
        resp.qty  = _M.unpack_u16(adu, 5)

    else
        return nil, _M.ERR_PARAM
    end

    return resp
end

-- ============================================================
-- 组帧：响应（从站用）
-- opts = {
--   dev_id = 1,
--   fc     = 0x03,
--   -- 读响应（01/02/03/04）：
--   data   = { 100, 200, ... },   -- 按位功能码时为 0/1 数组
--   -- 写单值响应（05/06）：
--   addr, value,
--   -- 写多值响应（0F/10）：
--   addr, qty,
-- }
-- 返回：adu 字符串；参数非法返回 nil
-- ============================================================
function _M.encode_response(opts)
    if type(opts) ~= "table" or not opts.dev_id or not opts.fc then
        return nil
    end
    local dev_id = math.floor(opts.dev_id) & 0xFF
    local fc     = math.floor(opts.fc) & 0xFF

    local pdu
    if is_read_fc(fc) then
        local data = opts.data
        if type(data) ~= "table" or #data == 0 then
            return nil
        end
        local qty = #data

        if is_bit_fc(fc) then
            -- 按位打包：第 1 个值放 bit0，低位在前
            local byte_count = math.floor((qty + 7) / 8)
            local bytes = {}
            for i = 1, byte_count do bytes[i] = 0 end
            for i = 1, qty do
                if data[i] and data[i] ~= 0 then
                    local bit = (i - 1) % 8
                    bytes[math.floor((i - 1) / 8) + 1] = bytes[math.floor((i - 1) / 8) + 1] | (1 << bit)
                end
            end
            pdu = string.char(dev_id, fc, byte_count) .. string.char(table.unpack(bytes))
        else
            local parts = { string.char(dev_id, fc, qty * 2) }
            for i = 1, qty do
                parts[#parts + 1] = _M.pack_u16(data[i] or 0)
            end
            pdu = table.concat(parts)
        end

    elseif fc == 0x05 or fc == 0x06 then
        if opts.addr == nil then return nil end
        local value = math.floor(opts.value or 0)
        if fc == 0x06 then
            value = value & 0xFFFF
        else
            value = (value ~= 0) and 0xFF00 or 0x0000
        end
        pdu = string.char(dev_id, fc) .. _M.pack_u16(opts.addr) .. _M.pack_u16(value)

    elseif fc == 0x0F or fc == 0x10 then
        if opts.addr == nil or not opts.qty then return nil end
        pdu = string.char(dev_id, fc) .. _M.pack_u16(opts.addr) .. _M.pack_u16(opts.qty)

    else
        return nil
    end

    return _M.adu_add_crc(pdu)
end

-- ============================================================
-- 组帧：异常响应（从站用）
-- 返回：adu 字符串（功能码最高位置 1 + 异常码）
-- ============================================================
function _M.encode_exception(dev_id, fc, code)
    if not dev_id or not fc or not code then
        return nil
    end
    if code < 1 or code > 0x0B then
        return nil
    end
    local pdu = string.char(math.floor(dev_id) & 0xFF,
                            (math.floor(fc) & 0x7F) | 0x80,
                            math.floor(code) & 0xFF)
    return _M.adu_add_crc(pdu)
end

-- ============================================================
-- 解帧：异常响应（主站用）
-- 返回：{ dev_id, fc, code } 或 nil, 错误码
-- ============================================================
function _M.decode_exception(adu)
    if type(adu) ~= "string" or #adu < 5 then
        return nil, _M.ERR_FRAME_SHORT
    end
    if not _M.adu_check_crc(adu) then
        return nil, _M.ERR_CRC
    end
    local fc_raw = adu:byte(2)
    if (fc_raw & 0x80) == 0 then
        return nil, _M.ERR_FC_MISMATCH
    end
    local code = adu:byte(3)
    if code < 1 or code > 0x0B then
        return nil, _M.ERR_EXCEPTION_CODE
    end
    return { dev_id = adu:byte(1), fc = fc_raw & 0x7F, code = code }
end

-- ============================================================
-- 工具：字节串转十六进制（每字节用空格分隔）
-- 例："\x01\x03\x19\x21" -> "01 03 19 21"（调试用）
-- ============================================================
function _M.to_hex(data)
    if type(data) ~= "string" or #data == 0 then
        return ""
    end
    local parts = {}
    for i = 1, #data do
        parts[#parts + 1] = string.format("%02X", data:byte(i))
    end
    return table.concat(parts, " ")
end

return _M
