--[[
@module  hardware
@summary RS485 底层收发模块（纯管道，不知道任何协议），支持 2 路串口
@version 3.2
@date    2026.11.06
@usage
1. 初始化 2 路 485 串口，每路的串口参数、方向控制完全独立配置
2. 对外暴露 u1/u2 各自的 send() / wait_response()
3. 同时保留 send() / wait_response() 作为 u1（下行设备口）的别名，兼容旧调用
4. 由上层协议解析器调用，不自动发送任何数据
]]

-- ============================================================
-- 配置区：u1（RS485_1，EN 软件翻转）
-- ============================================================
local u1_uartid      = 1
local u1_baudrate    = 9600      -- 波特率
local u1_databits    = 8         -- 数据位
local u1_stopbits    = 2         -- 停止位
local u1_parity      = uart.NONE -- 校验位：uart.NONE / uart.ODD / uart.EVEN
local u1_order       = uart.LSB  -- 位序
local u1_buf_size    = 1024      -- 接收缓冲区大小
local u1_en_pin      = 25        -- 方向控制脚（TODO 按实物接线确认）
local u1_en_level    = 0         -- 接收方向的 EN 电平（0=EN 低时接收）
local u1_rs485_delay = 20000     -- 发送→接收切换延时（微秒），9600 波特率经验值

-- ============================================================
-- 配置区：u2（RS485_2，EN 硬件自动翻转）
-- ============================================================
local u2_uartid      = 2
local u2_baudrate    = 9600
local u2_databits    = 8
local u2_stopbits    = 1
local u2_parity      = uart.NONE
local u2_order       = uart.LSB
local u2_buf_size    = 1024
local u2_en_pin      = nil       -- 硬件自动翻转，必须留空
local u2_en_level    = 0
local u2_rs485_delay = 20000

-- ============================================================
-- 配置区：接收侧的公共参数
-- ============================================================
-- 帧内静默间隔（毫秒）：连续无新数据超过此值视为一帧结束
-- 9600 波特率下 1 字节约 1.15ms，Modbus 规定帧间静默 3.5 字符 ≈ 4ms
-- 取 8ms 既有余量，又把每笔事务的固定延迟从 20ms 降到 8ms
local frame_gap_ms  = 8
local recv_max_read = 256       -- 单次 uart.read 最大字节数

-- 接收钩子：装了就进入"收到就抛给外部"的纯被动接收模式（仅供测试/调试）
-- 未装时保持原来的 wait_response 问答模式，两种模式互斥
local recv_hook = nil

-- ============================================================
-- 内部状态：每路一套，互不干扰
-- ============================================================
local u1_port = {
    name        = "u1",
    uartid      = u1_uartid,
    baudrate    = u1_baudrate,
    databits    = u1_databits,
    stopbits    = u1_stopbits,
    parity      = u1_parity,
    order       = u1_order,
    buf_size    = u1_buf_size,
    en_pin      = u1_en_pin,
    en_level    = u1_en_level,
    rs485_delay = u1_rs485_delay,
    resp_event  = "UART485_U1_RESP",
    resp_buffer = nil,
    clear_rx_on_send = true,    -- u1 是问答式，发送前清残留
}

local u2_port = {
    name        = "u2",
    uartid      = u2_uartid,
    baudrate    = u2_baudrate,
    databits    = u2_databits,
    stopbits    = u2_stopbits,
    parity      = u2_parity,
    order       = u2_order,
    buf_size    = u2_buf_size,
    en_pin      = u2_en_pin,
    en_level    = u2_en_level,
    rs485_delay = u2_rs485_delay,
    resp_event  = "UART485_U2_RESP",
    resp_buffer = nil,
    -- u2 不清：从站处理/等锁期间到达的上行请求必须保留，否则会被静默丢弃
    clear_rx_on_send = false,
}

-- 串口 id -> 端口状态，用于接收回调里分发
local port_by_uartid = {
    [u1_uartid] = u1_port,
    [u2_uartid] = u2_port,
}

-- ============================================================
-- 内部工具：字节串转十六进制，每个字节之间用空格分隔
-- 例："\x01\x03\x19\x21" -> "01 03 19 21"
-- ============================================================
local function to_hex_spaced(data)
    local parts = {}
    for i = 1, #data do
        parts[#parts + 1] = string.format("%02X", data:byte(i))
    end
    return table.concat(parts, " ")
end

-- ============================================================
-- 接收回调（2 路共用）：读走该串口所有可用数据，追加到对应暂存区
-- 未装接收钩子时：发布该路事件，唤醒正在等待的 wait_response
-- 装了接收钩子时：把这一批数据直接交给钩子（测试/调试模式），不再走 wait_response
-- ============================================================
local function port_recv_cb(id, len)
    local port = port_by_uartid[id]
    if not port then
        return
    end

    local s = ""
    repeat
        s = uart.read(id, recv_max_read)
        if #s > 0 then
            port.resp_buffer = (port.resp_buffer or "") .. s
        end
    until s == ""

    if port.resp_buffer and #port.resp_buffer > 0 then
        if recv_hook then
            local data = port.resp_buffer
            port.resp_buffer = nil
            recv_hook(port.name, data)
        else
            sys.publish(port.resp_event)
        end
    end
end

-- ============================================================
-- 发送完成回调（2 路共用，仅打印日志）
-- ============================================================
local function port_sent_cb(id)
    -- log.info("485", "sent", "uart=" .. id, "发送完成")
end

-- ============================================================
-- 对外接口实现（2 路共用逻辑，按 port 参数区分）
-- ============================================================
local function port_send(port, data)
    if type(data) ~= "string" or #data == 0 then
        log.warn("485", port.name .. " send 无效数据")
        return false
    end

    -- 清掉上一次可能残留的接收数据（仅 u1；u2 保留待处理的上行请求）
    if port.clear_rx_on_send then
        port.resp_buffer = nil
        if uart.rxClear then
            uart.rxClear(port.uartid)
        end
    end

    log.info("485", "send", port.name, "uart=" .. port.uartid,
             "len=" .. #data, "hex=" .. to_hex_spaced(data))
    uart.write(port.uartid, data)
    return true
end

local function port_wait_response(port, timeout_ms)
    local t0 = mcu.ticks()

    -- 阶段1：等待首段数据到达
    while not (port.resp_buffer and #port.resp_buffer > 0) do
        local remain = timeout_ms - (mcu.ticks() - t0)
        if remain <= 0 then
            log.warn("485", "wait_response", port.name .. " 超时(" .. timeout_ms .. "ms)")
            return nil, -1
        end
        if not sys.waitUntil(port.resp_event, remain) then
            log.warn("485", "wait_response", port.name .. " 超时(" .. timeout_ms .. "ms)")
            return nil, -1
        end
    end

    -- 阶段2：等总线静默（连续 frame_gap_ms 没有新数据，认为一帧收完）
    local last_len
    repeat
        if not port.resp_buffer then
            -- resp_buffer 被其他协程清掉了（理论上不应该，除非并发调用）
            log.warn("485", "wait_response", port.name .. " resp_buffer 意外为 nil")
            return nil, -2
        end
        last_len = #port.resp_buffer
        sys.wait(frame_gap_ms)
    until port.resp_buffer and #port.resp_buffer == last_len

    local data = port.resp_buffer
    port.resp_buffer = nil

    log.info("485", "recv", port.name, "uart=" .. port.uartid,
             "len=" .. #data, "hex=" .. to_hex_spaced(data))
    return data, 0
end

-- ============================================================
-- 对外接口：u1 / u2 各一套
-- ============================================================
local function u1_send(data)
    return port_send(u1_port, data)
end

local function u1_wait_response(timeout_ms)
    return port_wait_response(u1_port, timeout_ms)
end

local function u2_send(data)
    return port_send(u2_port, data)
end

local function u2_wait_response(timeout_ms)
    return port_wait_response(u2_port, timeout_ms)
end

-- ============================================================
-- 初始化（require 时自动执行）
-- ============================================================
local function port_init(port)
    log.info("485", "init", port.name,
             "uart=" .. port.uartid,
             "baud=" .. port.baudrate,
             "data=" .. port.databits,
             "stop=" .. port.stopbits,
             "parity=" .. tostring(port.parity),
             "en_pin=" .. tostring(port.en_pin),
             "delay=" .. port.rs485_delay .. "us")

    -- en_pin 为 nil 时，uart.setup 不会做方向切换（适配硬件自动翻转的 485）
    uart.setup(port.uartid, port.baudrate, port.databits, port.stopbits,
               port.parity, port.order, port.buf_size,
               port.en_pin, port.en_level, port.rs485_delay)

    uart.on(port.uartid, "receive", port_recv_cb)
    uart.on(port.uartid, "sent", port_sent_cb)
end

port_init(u1_port)
port_init(u2_port)
log.info("485", "init", "2 路 485 初始化完成")

-- ============================================================
-- 模块导出
-- ============================================================
local _M = {}

-- 两路各自接口
_M.u1_send          = u1_send
_M.u1_wait_response = u1_wait_response
_M.u2_send          = u2_send
_M.u2_wait_response = u2_wait_response

-- 兼容旧接口：默认指向 u1（下行设备口）
_M.send          = u1_send
_M.wait_response = u1_wait_response

-- 安装接收钩子（仅供测试/调试）：收到数据时回调 fn(端口名, 数据)
-- 装了之后 wait_response 不再收数据，两种模式互斥；传 nil 可卸载
_M.set_recv_hook = function(fn)
    recv_hook = fn
end

return _M
