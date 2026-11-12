--[[
@module  slave
@summary Modbus 从站（上行，走 u2 串口，多从机地址支持）
@version 1.1
@date    2026.11.12
@usage
1. require 即启动：等 u2 上的 Modbus 请求
2. 从站地址白名单 = 点表 meta.slave_dev 里所有值 + 广播 0x00
3. 读请求（0x01/0x02/0x03/0x04）：按 (dev_id, n_addr) 查缓存
4. 写请求（0x05/0x06）：转 A 的(dev_id, s_addr) → u1 写穿透 → 更新缓存 → 回显
5. 写多个线圈（0x0F）：地址须全为可写线圈且下行地址连续 → 一次 0x0F 穿透 → 批量更新
6. 写多个寄存器（0x10）：按点位组切分，允许一条请求跨多个组；
   每个组必须完整覆盖（从组首开始、数量 = reg_count），不允许只写半组；
   组内 reg_count>1 走一次 0x10，reg_count==1 走一次 0x06
7. 失败时返回真实错误码（0x01/0x02/0x04/0x0B/从机异常）
8. 不支持的功能码直接返回 0x01（非法功能码）
]]

local uart485 = require "hardware"
local core    = require "core"
local shared  = require "shared"
local pt      = require "point_table"

-- ============================================================
-- 配置
-- ============================================================
local RESPONSE_TIMEOUT  = 200     -- 读请求等缓存的时间（纯查缓存，应该瞬间）
local WRITE_TIMEOUT     = 2000    -- 写穿透：单次 0x06 / 0x05 等从机的时间

-- ============================================================
-- 从站地址白名单：从点表 meta.slave_dev 派生，加上广播 0x00
-- ============================================================
local accepted_dev = {}
local slave_dev_list = pt.meta.slave_dev or {}
for _, d in ipairs(slave_dev_list) do
    accepted_dev[d] = true
end
accepted_dev[0] = true  -- 广播地址始终允许（但广播请求不回显）

-- 错误码优先级（越靠前越高，读请求遇到多个错误时取最高的返回）
local ERR_PRIORITY = {
    [0x02] = 5,  -- 非法地址
    [0x03] = 4,  -- 非法值
    [0x04] = 3,  -- 从站故障
    [0x05] = 2,  -- 确认
    [0x06] = 2,  -- 忙
}
local function err_priority(code)
    return ERR_PRIORITY[code] or 1
end

-- ============================================================
-- 内部：处理读请求（0x01/0x02/0x03/0x04）
-- ============================================================
local function handle_read(req)
    local values = {}
    local first_err = nil
    local first_err_prio = 0

    for i = 0, req.qty - 1 do
        local n_addr = req.addr + i
        local slot_data, slot_err = shared.read_by_b(req.dev_id, n_addr)

        if slot_data == nil and slot_err == 0x02 then
            return core.encode_exception(req.dev_id, req.fc, core.EXCEPTION_ILLEGAL_DATA_ADDRESS)
        end

        if slot_err and slot_err ~= 0 then
            local prio = err_priority(slot_err)
            if prio > first_err_prio then
                first_err = slot_err
                first_err_prio = prio
            end
        end

        values[#values + 1] = slot_data or 0
    end

    if first_err then
        return core.encode_exception(req.dev_id, req.fc, first_err)
    end

    return core.encode_response({
        dev_id = req.dev_id,
        fc     = req.fc,
        data   = values,
    })
end

-- ============================================================
-- 内部：处理写单个寄存器（0x06）
-- ============================================================
local function handle_write_single(req)
    local n_addr = req.addr

    local reg = shared.get_reg_by_b(req.dev_id, n_addr)
    if not reg then
        log.warn("slave", "写 非法 dev_id+n_addr=0x" .. string.format("%02X", req.dev_id)
                 .. "." .. n_addr)
        return core.encode_exception(req.dev_id, req.fc, core.EXCEPTION_ILLEGAL_DATA_ADDRESS)
    end

    if reg.reg_type ~= 3 or reg.rw ~= "rw" then
        log.warn("slave", "写 不可写 n_addr=" .. n_addr ..
                 " reg_type=" .. reg.reg_type .. " rw=" .. reg.rw)
        return core.encode_exception(req.dev_id, req.fc, core.EXCEPTION_ILLEGAL_FUNCTION)
    end

    if reg.reg_count > 1 then
        log.warn("slave", "写 多寄存器点位不支持 0x06",
                 "n_addr=" .. n_addr, "reg_count=" .. reg.reg_count,
                 "请用 0x10 写整组 n_addr=" .. reg.base_n_addr)
        return core.encode_exception(req.dev_id, req.fc, core.EXCEPTION_ILLEGAL_DATA_ADDRESS)
    end

    local adu = core.encode_request({
        dev_id = reg.dev_id,
        fc     = core.FC_WRITE_SINGLE_REGISTER,
        addr   = reg.s_addr,
        value  = req.value,
    })
    if not adu then
        return core.encode_exception(req.dev_id, req.fc, core.EXCEPTION_ILLEGAL_DATA_VALUE)
    end

    if not shared.lock("slave_write_06") then
        log.warn("slave", "写穿透 获取 u1 锁超时")
        return core.encode_exception(req.dev_id, req.fc, core.EXCEPTION_GATEWAY_TARGET_FAILED)
    end

    uart485.u1_send(adu)
    local resp_adu, code = uart485.u1_wait_response(WRITE_TIMEOUT)
    shared.unlock()

    if not resp_adu then
        log.warn("slave", "写穿透 超时 dev=" .. reg.dev_id .. " s_addr=" .. reg.s_addr)
        shared.write_by_a(reg.dev_id, reg.s_addr, req.value, core.EXCEPTION_GATEWAY_TARGET_FAILED)
        return core.encode_exception(req.dev_id, req.fc, core.EXCEPTION_GATEWAY_TARGET_FAILED)
    end

    local resp, err = core.decode_response(resp_adu, core.FC_WRITE_SINGLE_REGISTER)
    if not resp then
        log.warn("slave", "写穿透 解帧失败 dev=" .. reg.dev_id ..
                 " s_addr=" .. reg.s_addr .. " 内部错误=0x" .. string.format("%02X", err))
        shared.write_by_a(reg.dev_id, reg.s_addr, req.value, core.EXCEPTION_SLAVE_DEVICE_FAILURE)
        return core.encode_exception(req.dev_id, req.fc, core.EXCEPTION_SLAVE_DEVICE_FAILURE)
    end

    if resp.is_exception then
        log.warn("slave", "写穿透 从机异常 dev=" .. reg.dev_id ..
                 " s_addr=" .. reg.s_addr .. " ec=0x" .. string.format("%02X", resp.exception_code))
        shared.write_by_a(reg.dev_id, reg.s_addr, req.value, resp.exception_code)
        return core.encode_exception(req.dev_id, req.fc, resp.exception_code)
    end

    shared.write_by_a(reg.dev_id, reg.s_addr, req.value, 0)
    log.info("slave", "写穿透成功",
             "B.dev=" .. req.dev_id .. ".n_addr=" .. n_addr ..
             "→ A.dev=" .. reg.dev_id .. ".s_addr=" .. reg.s_addr,
             "value=0x" .. string.format("%04X", req.value))

    return core.encode_response({
        dev_id = req.dev_id,
        fc     = req.fc,
        addr   = n_addr,
        value  = req.value,
    })
end

-- ============================================================
-- 内部：处理写单个线圈（0x05）
-- ============================================================
local function handle_write_single_coil(req)
    local n_addr = req.addr

    local reg = shared.get_reg_by_b(req.dev_id, n_addr)
    if not reg then
        log.warn("slave", "写线圈 非法 dev_id+n_addr=0x" .. string.format("%02X", req.dev_id)
                 .. "." .. n_addr)
        return core.encode_exception(req.dev_id, req.fc, core.EXCEPTION_ILLEGAL_DATA_ADDRESS)
    end

    if reg.reg_type ~= 1 or reg.rw ~= "rw" then
        log.warn("slave", "写线圈 不可写 n_addr=" .. n_addr ..
                 " reg_type=" .. reg.reg_type .. " rw=" .. reg.rw)
        return core.encode_exception(req.dev_id, req.fc, core.EXCEPTION_ILLEGAL_FUNCTION)
    end

    local coil_val = (req.value == 0xFF00) and 1 or 0

    local adu = core.encode_request({
        dev_id = reg.dev_id,
        fc     = core.FC_WRITE_SINGLE_COIL,
        addr   = reg.s_addr,
        value  = coil_val,
    })
    if not adu then
        return core.encode_exception(req.dev_id, req.fc, core.EXCEPTION_ILLEGAL_DATA_VALUE)
    end

    if not shared.lock("slave_write_05") then
        log.warn("slave", "写线圈 获取 u1 锁超时")
        return core.encode_exception(req.dev_id, req.fc, core.EXCEPTION_GATEWAY_TARGET_FAILED)
    end

    uart485.u1_send(adu)
    local resp_adu = uart485.u1_wait_response(WRITE_TIMEOUT)
    shared.unlock()

    if not resp_adu then
        log.warn("slave", "写线圈 超时 dev=" .. reg.dev_id .. " s_addr=" .. reg.s_addr)
        shared.write_by_a(reg.dev_id, reg.s_addr, coil_val, core.EXCEPTION_GATEWAY_TARGET_FAILED)
        return core.encode_exception(req.dev_id, req.fc, core.EXCEPTION_GATEWAY_TARGET_FAILED)
    end

    local resp, err = core.decode_response(resp_adu, core.FC_WRITE_SINGLE_COIL)
    if not resp then
        log.warn("slave", "写线圈 解帧失败 dev=" .. reg.dev_id .. " s_addr=" .. reg.s_addr ..
                 " 内部错误=0x" .. string.format("%02X", err))
        shared.write_by_a(reg.dev_id, reg.s_addr, coil_val, core.EXCEPTION_SLAVE_DEVICE_FAILURE)
        return core.encode_exception(req.dev_id, req.fc, core.EXCEPTION_SLAVE_DEVICE_FAILURE)
    end

    if resp.is_exception then
        log.warn("slave", "写线圈 从机异常 dev=" .. reg.dev_id .. " s_addr=" .. reg.s_addr ..
                 " ec=0x" .. string.format("%02X", resp.exception_code))
        shared.write_by_a(reg.dev_id, reg.s_addr, coil_val, resp.exception_code)
        return core.encode_exception(req.dev_id, req.fc, resp.exception_code)
    end

    shared.write_by_a(reg.dev_id, reg.s_addr, coil_val, 0)
    log.info("slave", "写线圈成功",
             "B.dev=" .. req.dev_id .. ".n_addr=" .. n_addr ..
             "→ A.dev=" .. reg.dev_id .. ".s_addr=" .. reg.s_addr,
             "value=" .. coil_val)

    return core.encode_response({
        dev_id = req.dev_id,
        fc     = req.fc,
        addr   = n_addr,
        value  = req.value,
    })
end

-- ============================================================
-- 内部：处理写多个线圈（0x0F）
-- ============================================================
local function handle_write_multiple_coils(req)
    local first_err = nil
    local regs = {}

    for i = 0, req.qty - 1 do
        local reg = shared.get_reg_by_b(req.dev_id, req.addr + i)
        if not reg then
            first_err = core.EXCEPTION_ILLEGAL_DATA_ADDRESS
            break
        end
        if reg.reg_type ~= 1 or reg.rw ~= "rw" then
            first_err = core.EXCEPTION_ILLEGAL_FUNCTION
            break
        end
        regs[i + 1] = reg
    end

    if not first_err then
        for i = 2, req.qty do
            if regs[i].dev_id ~= regs[1].dev_id
                or regs[i].s_addr ~= regs[1].s_addr + (i - 1)
            then
                first_err = core.EXCEPTION_ILLEGAL_DATA_ADDRESS
                break
            end
        end
    end

    if first_err then
        log.warn("slave", "写线圈(多) 校验失败 错误码=0x" .. string.format("%02X", first_err),
                 "B.dev=" .. req.dev_id .. ".n_addr=" .. req.addr .. " qty=" .. req.qty)
        return core.encode_exception(req.dev_id, req.fc, first_err)
    end

    local values = req.values

    local adu = core.encode_request({
        dev_id = regs[1].dev_id,
        fc     = core.FC_WRITE_MULTIPLE_COILS,
        addr   = regs[1].s_addr,
        qty    = req.qty,
        values = values,
    })
    if not adu then
        log.warn("slave", "写线圈(多) 组帧失败 qty=" .. req.qty)
        return core.encode_exception(req.dev_id, req.fc, core.EXCEPTION_ILLEGAL_DATA_VALUE)
    end

    if not shared.lock("slave_write_0f") then
        log.warn("slave", "写线圈(多) 获取 u1 锁超时")
        return core.encode_exception(req.dev_id, req.fc, core.EXCEPTION_GATEWAY_TARGET_FAILED)
    end

    uart485.u1_send(adu)
    local resp_adu = uart485.u1_wait_response(WRITE_TIMEOUT)
    shared.unlock()

    if not resp_adu then
        log.warn("slave", "写线圈(多) 超时 dev=" .. regs[1].dev_id ..
                 " s_addr=" .. regs[1].s_addr .. " qty=" .. req.qty)
        return core.encode_exception(req.dev_id, req.fc, core.EXCEPTION_GATEWAY_TARGET_FAILED)
    end

    local resp, err = core.decode_response(resp_adu, core.FC_WRITE_MULTIPLE_COILS)
    if not resp then
        log.warn("slave", "写线圈(多) 解帧失败 内部错误=0x" .. string.format("%02X", err))
        return core.encode_exception(req.dev_id, req.fc, core.EXCEPTION_SLAVE_DEVICE_FAILURE)
    end

    if resp.is_exception then
        log.warn("slave", "写线圈(多) 从机异常 ec=0x" .. string.format("%02X", resp.exception_code))
        return core.encode_exception(req.dev_id, req.fc, resp.exception_code)
    end

    for i = 1, req.qty do
        shared.write_by_a(regs[i].dev_id, regs[i].s_addr,
                         (values[i] and values[i] ~= 0) and 1 or 0, 0)
    end

    log.info("slave", "写线圈(多)成功",
             "B.dev=" .. req.dev_id .. ".n_addr=" .. req.addr .. " qty=" .. req.qty)
    return core.encode_response({
        dev_id = req.dev_id,
        fc     = req.fc,
        addr   = req.addr,
        qty    = req.qty,
    })
end

-- ============================================================
-- 内部：处理写多个寄存器（0x10）
-- ============================================================
local function handle_write_multiple(req)
    local regs = {}
    for i = 0, req.qty - 1 do
        local n_addr = req.addr + i
        local reg = shared.get_reg_by_b(req.dev_id, n_addr)

        if not reg then
            log.warn("slave", "写穿透(多) 校验失败 错误码=0x02",
                     "B.dev=" .. req.dev_id .. ".n_addr=" .. n_addr .. " 未配置")
            return core.encode_exception(req.dev_id, req.fc, core.EXCEPTION_ILLEGAL_DATA_ADDRESS)
        end
        if reg.reg_type ~= 3 or reg.rw ~= "rw" then
            log.warn("slave", "写穿透(多) 校验失败 错误码=0x01",
                     "B.dev=" .. req.dev_id .. ".n_addr=" .. n_addr ..
                     " reg_type=" .. reg.reg_type .. " rw=" .. tostring(reg.rw))
            return core.encode_exception(req.dev_id, req.fc, core.EXCEPTION_ILLEGAL_FUNCTION)
        end
        regs[i + 1] = reg
    end

    local groups = {}
    local cur = nil
    for i = 1, req.qty do
        local reg  = regs[i]
        local base = reg.base_n_addr or reg.n_addr
        if not cur or cur.base_n_addr ~= base then
            cur = {
                base_n_addr = base,
                base_s_addr = reg.base_s_addr or reg.s_addr,
                reg_count   = reg.reg_count or 1,
                regs        = {},
                values      = {},
            }
            groups[#groups + 1] = cur
        end
        cur.regs[#cur.regs + 1]     = reg
        cur.values[#cur.values + 1] = req.values[i]
    end

    for _, grp in ipairs(groups) do
        if grp.regs[1].n_addr ~= grp.base_n_addr or #grp.regs ~= grp.reg_count then
            log.warn("slave", "写穿透(多) 校验失败 错误码=0x02",
                     "B.dev=" .. req.dev_id .. ".n_addr=" .. req.addr .. " qty=" .. req.qty ..
                     " 组首=" .. grp.base_n_addr .. " 覆盖首=" .. grp.regs[1].n_addr ..
                     " 覆盖数=" .. #grp.regs .. " 组大小=" .. grp.reg_count)
            return core.encode_exception(req.dev_id, req.fc, core.EXCEPTION_ILLEGAL_DATA_ADDRESS)
        end
    end

    if not shared.lock("slave_write_10") then
        log.warn("slave", "写穿透(多) 获取 u1 锁超时")
        return core.encode_exception(req.dev_id, req.fc, core.EXCEPTION_GATEWAY_TARGET_FAILED)
    end

    local first_err = nil

    for _, grp in ipairs(groups) do
        if grp.reg_count > 1 then
            local adu = core.encode_request({
                dev_id = grp.regs[1].dev_id,
                fc     = core.FC_WRITE_MULTIPLE_REGISTERS,
                addr   = grp.base_s_addr,
                qty    = grp.reg_count,
                values = grp.values,
            })
            if not adu then
                first_err = core.EXCEPTION_ILLEGAL_DATA_VALUE
                break
            end

            uart485.u1_send(adu)
            local resp_adu = uart485.u1_wait_response(WRITE_TIMEOUT)

            if not resp_adu then
                first_err = core.EXCEPTION_GATEWAY_TARGET_FAILED
                break
            end

            local resp, err = core.decode_response(resp_adu, core.FC_WRITE_MULTIPLE_REGISTERS)
            if not resp then
                first_err = core.EXCEPTION_SLAVE_DEVICE_FAILURE
                log.warn("slave", "写穿透(多) 解帧失败 内部错误=0x" ..
                         string.format("%02X", err))
                break
            end
            if resp.is_exception then
                first_err = resp.exception_code
                break
            end

            for k, reg in ipairs(grp.regs) do
                shared.write_by_a(reg.dev_id, reg.s_addr, grp.values[k], 0)
            end
        else
            local reg = grp.regs[1]
            local adu = core.encode_request({
                dev_id = reg.dev_id,
                fc     = core.FC_WRITE_SINGLE_REGISTER,
                addr   = reg.s_addr,
                value  = grp.values[1],
            })
            if not adu then
                first_err = core.EXCEPTION_ILLEGAL_DATA_VALUE
                break
            end

            uart485.u1_send(adu)
            local resp_adu = uart485.u1_wait_response(WRITE_TIMEOUT)

            if not resp_adu then
                first_err = core.EXCEPTION_GATEWAY_TARGET_FAILED
                break
            end

            local resp, err = core.decode_response(resp_adu, core.FC_WRITE_SINGLE_REGISTER)
            if not resp then
                first_err = core.EXCEPTION_SLAVE_DEVICE_FAILURE
                break
            end
            if resp.is_exception then
                first_err = resp.exception_code
                break
            end

            shared.write_by_a(reg.dev_id, reg.s_addr, grp.values[1], 0)
        end
    end

    shared.unlock()

    if first_err then
        log.warn("slave", "写穿透(多) 失败 错误码=0x" .. string.format("%02X", first_err),
                 "B.dev=" .. req.dev_id .. ".n_addr=" .. req.addr .. " qty=" .. req.qty)
        return core.encode_exception(req.dev_id, req.fc, first_err)
    end

    log.info("slave", "写穿透(多)成功",
             "B.dev=" .. req.dev_id .. ".n_addr=" .. req.addr .. " qty=" .. req.qty ..
             " 组数=" .. #groups)
    return core.encode_response({
        dev_id = req.dev_id,
        fc     = req.fc,
        addr   = req.addr,
        qty    = req.qty,
    })
end

-- ============================================================
-- 主循环
-- ============================================================
sys.taskInit(function()
    sys.wait(3000)

    while shared.get_all_regs() == nil or #shared.get_all_regs() == 0 do
        sys.wait(500)
    end

    local accepted_str = {}
    for _, d in ipairs(slave_dev_list) do
        accepted_str[#accepted_str + 1] = "0x" .. string.format("%02X", d)
    end
    log.info("slave", "从站启动",
             "串口=u2",
             "接受地址=[" .. table.concat(accepted_str, ", ") .. "]",
             "广播=0x00")

    while true do
        local adu = uart485.u2_wait_response(60000)
        if not adu then
            goto continue
        end

        local req, err = core.decode_request(adu)
        if not req then
            log.warn("slave", "解请求失败 err=0x" .. string.format("%02X", err))
            goto continue
        end

        if not accepted_dev[req.dev_id] then
            goto continue
        end

        local resp
        if req.fc == core.FC_READ_COILS
            or req.fc == core.FC_READ_DISCRETE_INPUTS
            or req.fc == core.FC_READ_HOLDING_REGISTERS
            or req.fc == core.FC_READ_INPUT_REGISTERS then
            resp = handle_read(req)

        elseif req.fc == core.FC_WRITE_SINGLE_COIL then
            resp = handle_write_single_coil(req)

        elseif req.fc == core.FC_WRITE_MULTIPLE_COILS then
            resp = handle_write_multiple_coils(req)

        elseif req.fc == core.FC_WRITE_SINGLE_REGISTER then
            resp = handle_write_single(req)

        elseif req.fc == core.FC_WRITE_MULTIPLE_REGISTERS then
            resp = handle_write_multiple(req)

        else
            log.warn("slave", "不支持的功能码 fc=0x" .. string.format("%02X", req.fc))
            resp = core.encode_exception(req.dev_id, req.fc, core.EXCEPTION_ILLEGAL_FUNCTION)
        end

        if resp and not req.broadcast then
            uart485.u2_send(resp)
        end

        ::continue::
    end
end)
