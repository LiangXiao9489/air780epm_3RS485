--[[
@module  master
@summary Modbus 主站轮询任务（下行，走 u1 串口）
@version 1.0
@date    2026.11.12
@usage
1. require 即启动：读点表 → 初始化缓存 → 开始轮询循环
2. 按 (dev_id, reg_type, s_addr) 排序后，把同一设备同一类型的连续 s_addr 合并成一次请求
3. 用 core.encode_request 组帧 → user_485.u1_send 发送 → wait_response 等响应
4. 用 core.decode_response 解帧 → store.write_by_a 更新缓存
5. 缓存更新后，上行从站（u2）立刻能读到新值
]]

local uart485         = require "hardware"
local core            = require "core"
local store           = require "store"
local downlink_lock   = require "downlink_uart_lock"
local pt              = require "point_table"

-- ============================================================
-- 配置
-- ============================================================
local POLL_INTERVAL_MS    = 5000   -- 每轮所有设备轮完后等待多久
-- 单次请求等响应超时：9600 波特率下从机正常回帧在 50ms 内
local RESPONSE_TIMEOUT_MS = 800
local FRAME_GAP_MS        = 20     -- 同一设备两次请求之间的间隔（防总线压力）

-- reg_type → Modbus 读功能码映射（reg_type 数字 = 功能码数字，业界惯例）
local REG_TYPE_TO_FC = {
    [1] = core.FC_READ_COILS,              -- 1:coil      → 0x01
    [2] = core.FC_READ_DISCRETE_INPUTS,    -- 2:discrete  → 0x02
    [3] = core.FC_READ_HOLDING_REGISTERS,  -- 3:holding   → 0x03
    [4] = core.FC_READ_INPUT_REGISTERS,    -- 4:input     → 0x04
}

-- ============================================================
-- 内部：把点表按 (dev_id, reg_type) 分块，连续 s_addr 合并
-- ============================================================
local function build_poll_blocks(all_regs)
    table.sort(all_regs, function(a, b)
        if a.dev_id ~= b.dev_id then return a.dev_id < b.dev_id end
        if a.reg_type ~= b.reg_type then return a.reg_type < b.reg_type end
        return a.s_addr < b.s_addr
    end)

    local blocks = {}
    local current_block = nil

    for _, r in ipairs(all_regs) do
        local fc = REG_TYPE_TO_FC[r.reg_type]

        if not fc then
            log.warn("master", "reg_type=" .. tostring(r.reg_type) .. " 不支持，跳过 dev_id=" .. r.dev_id)
        else
            local qty_limit = core.is_bit_fc(fc) and core.MAX_READ_BITS or core.MAX_READ_REGS

            if not current_block
                or current_block.dev_id ~= r.dev_id
                or current_block.fc ~= fc
                or r.s_addr ~= current_block.start_addr + #current_block.regs
                or #current_block.regs >= qty_limit
            then
                current_block = {
                    dev_id     = r.dev_id,
                    fc         = fc,
                    start_addr = r.s_addr,
                    regs       = { r },
                }
                blocks[#blocks + 1] = current_block
            else
                current_block.regs[#current_block.regs + 1] = r
            end
        end
    end

    return blocks
end

-- ============================================================
-- 内部：轮询单个块（一次请求读一段连续寄存器）
-- ============================================================
local function poll_block(block)
    local qty = #block.regs
    local qty_limit = core.is_bit_fc(block.fc) and core.MAX_READ_BITS or core.MAX_READ_REGS
    if qty < 1 or qty > qty_limit then
        log.warn("master", "qty 越界，跳过 dev=" .. block.dev_id)
        return false
    end

    local adu = core.encode_request({
        dev_id = block.dev_id,
        fc     = block.fc,
        addr   = block.start_addr,
        qty    = qty,
    })
    if not adu then
        log.warn("master", "encode_request 失败 dev=" .. block.dev_id)
        return false
    end

    -- 获取 u1 互斥锁（写穿透可能正在用 u1，等它用完）
    if not downlink_lock.lock("master_poll") then
        log.warn("master", "获取 u1 锁超时，跳过 dev=" .. block.dev_id)
        return false
    end

    uart485.u1_send(adu)
    local resp_adu, code = uart485.u1_wait_response(RESPONSE_TIMEOUT_MS)
    downlink_lock.unlock()

    if not resp_adu then
        log.warn("master", "无响应 dev=" .. block.dev_id .. " fc=" .. block.fc,
                 "qty=" .. qty)
        for _, r in ipairs(block.regs) do
            store.write_by_a(r.dev_id, r.s_addr, 0xFFFF, core.EXCEPTION_GATEWAY_TARGET_FAILED)
        end
        return false
    end

    local resp, err = core.decode_response(resp_adu, block.fc)
    if not resp then
        log.warn("master", "decode_response 失败 dev=" .. block.dev_id,
                 "内部错误码=0x" .. string.format("%02X", err))
        for _, r in ipairs(block.regs) do
            store.write_by_a(r.dev_id, r.s_addr, 0xFFFF, core.EXCEPTION_SLAVE_DEVICE_FAILURE)
        end
        return false
    end

    if resp.is_exception then
        log.warn("master", "异常响应 dev=" .. block.dev_id,
                 "fc=0x" .. string.format("%02X", block.fc),
                 "异常码=0x" .. string.format("%02X", resp.exception_code))
        for _, r in ipairs(block.regs) do
            store.write_by_a(r.dev_id, r.s_addr, 0xFFFF, resp.exception_code)
        end
        return false
    end

    for i, reg in ipairs(block.regs) do
        local raw = resp.values[i]
        if raw == nil then
            log.warn("master", "响应缺值 dev=" .. block.dev_id,
                     "s_addr=" .. reg.s_addr .. " 期望第" .. i .. "个值")
            store.write_by_a(reg.dev_id, reg.s_addr, 0xFFFF, core.EXCEPTION_SLAVE_DEVICE_FAILURE)
        else
            store.write_by_a(reg.dev_id, reg.s_addr, raw, 0)
        end
    end

    log.info("master", "轮询成功",
             "dev=" .. block.dev_id,
             "fc=0x" .. string.format("%02X", block.fc),
             "addr=" .. block.start_addr,
             "qty=" .. qty)
    return true
end

-- ============================================================
-- 主循环
-- ============================================================
sys.taskInit(function()
    if not store.init(pt) then
        log.error("master", "缓存初始化失败，主站停止")
        return
    end

    sys.wait(3000)

    log.info("master", "主站轮询启动",
             "串口=u1",
             "轮询间隔=" .. POLL_INTERVAL_MS .. "ms")

    local round = 0
    local total_ok = 0
    local total_fail = 0
    while true do
        round = round + 1

        local all_regs = store.get_all_regs()
        local blocks = build_poll_blocks(all_regs)

        log.info("master", "第 " .. round .. " 轮开始", "块数=" .. #blocks)

        local ok_count = 0
        local fail_count = 0

        for _, block in ipairs(blocks) do
            -- 有上行写穿透在等 u1 时，先让出总线
            local wait_tick = 0
            while downlink_lock.has_waiter() and wait_tick < 200 do
                sys.wait(10)
                wait_tick = wait_tick + 10
            end

            if poll_block(block) then
                ok_count = ok_count + 1
            else
                fail_count = fail_count + 1
            end
            sys.wait(FRAME_GAP_MS)
        end

        total_ok   = total_ok + ok_count
        total_fail = total_fail + fail_count
        local total = total_ok + total_fail
        local rate = (total > 0) and (total_ok * 100.0 / total) or 0

        log.info("master", "第 " .. round .. " 轮结束",
                 "成功=" .. ok_count, "失败=" .. fail_count,
                 "累计成功=" .. total_ok, "累计失败=" .. total_fail,
                 "成功率=" .. string.format("%.2f%%", rate))

        sys.wait(POLL_INTERVAL_MS)
    end
end)
