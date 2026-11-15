--[[
@module  report
@summary MQTT 上行定时上报：real（整点全量）/ change（变化）/ realIndex（首页快速）
@version 1.0
@date    2026.11.14
@usage
require 即启动一个 task，负责三件事：

1. real 全量上报：按 config.upload_interval_min 对齐整分钟（如 15:00:00 / 15:05:00），
   ti 和每个 tag 的 t 都用整点时间，q=1 表示采集正常；
2. change 变化上报：每 config.change_check_sec 秒对比一次快照，只报有变化的 tag；
3. realIndex 快速上报：由 down.lua 的 indexReal 指令调 report.start_index_real(msg)
   → 立刻上行一次，之后按 iv 周期上行，持续 du 秒后自动恢复。

数据来源：store.get_point_values()（master 轮询填充的缓存）
上行出口：sender.publish(topics.UP_DATA, payload, 1)

协议要点（见 mqtt协议内容.md）：
- tag 内 q 是质量位 0/1，采集成功必须为 "1"，否则服务端不存储；
- tag 内 t 是 unix 秒字符串；外层 ti 是 "2018-10-10 16:01:47" 格式；
- real 必须整 5 分钟上报（ti 和 t 都要整点）。
]]

local topics = require "topics"
local store  = require "store"
local up     = require "up"
local ack    = require "ack"
local sender = require "sender"
local config = require "config"

local report = {}

-- 外部唤醒事件：indexReal 指令到达时 publish 一下，让 task 立刻重算等待时间
local WAKE_TOPIC = "MQTT_REPORT_WAKE"

-- ============================================================
-- 时间有效性门限
-- 上电后系统时钟未被 NITZ/NTP 校准前，os.time() 停在 2000-01-01，
-- 此时按整点对齐会算出 2000-01-01 08:05:00 这种假时间戳上报，必须先拦住。
-- 1600000000 ≈ 2020-09-13 12:26:40 UTC
-- ============================================================
local TIME_VALID_MIN = 1600000000
local last_time_warn = -1000

local function time_ok(tag)
    local now = os.time()
    if now >= TIME_VALID_MIN then return true end

    -- 每 30 秒最多提示一次，避免刷屏
    if now - last_time_warn >= 30 then
        last_time_warn = now
        log.warn("mqtt.report", "系统时间未同步，暂不上报", tag,
                 os.date("%Y-%m-%d %H:%M:%S", now))
    end
    return false
end

-- indexReal 里 iv 的单位：协议正文写"毫秒"，但示例 iv:"5" 且需求是"5秒一上送"
-- 这里按秒解释；若服务端确实下发毫秒值，把这里改成 false
local IV_IS_SECOND = true

-- 快速上报状态
local fast = {
    active    = false,
    deadline  = 0,     -- 到期时间（unix 秒）
    iv_sec    = 5,     -- 上报周期（秒）
    next_send = 0,     -- 下次上报时间
    targets   = {},    -- { [dev_id] = { [tag] = true } }
}

-- 上次上报快照，用于 change 对比
-- last[dev_id][tag] = { v = 数字, q = 0/1 }
local last = {}

local function now_str(ts)
    return os.date("%Y-%m-%d %H:%M:%S", ts)
end

local function store_ready()
    local regs = store.get_all_regs()
    return regs and #regs > 0
end

-- 采集成功 → q="1"；失败 → q="0"（协议：q=1 服务端才存储）
local function quality_of(errcode)
    return (errcode == 0) and "1" or "0"
end

-- 构建上报用的数据表
-- filter: nil = 全部点位；否则 { [dev_id] = { [tag] = true } }
-- fixed_ts: 数字时所有 tag 都用这个时间戳（real 整点）；nil 时用各点自己的采集时间
local function build_data(filter, fixed_ts)
    local d = {}
    for _, p in ipairs(store.get_point_values()) do
        local keep = (filter == nil)
        if not keep then
            local ft = filter[p.dev_id]
            keep = (ft ~= nil) and (ft[p.tag] == true)
        end

        if keep then
            local v  = (p.values and p.values[1]) or 0
            local ts = fixed_ts or p.ts
            if not ts or ts == 0 then ts = os.time() end

            local dev_key = tostring(p.dev_id)
            d[dev_key] = d[dev_key] or {}
            d[dev_key][p.tag] = {
                q = quality_of(p.errcode),
                t = tostring(ts),
                v = tostring(v),
            }
        end
    end
    return d
end

local function has_any(d)
    for _ in pairs(d) do return true end
    return false
end

-- 把当前所有点位写进快照（real 上报后调用）
local function commit_snapshot()
    for _, p in ipairs(store.get_point_values()) do
        last[p.dev_id] = last[p.dev_id] or {}
        last[p.dev_id][p.tag] = {
            v = (p.values and p.values[1]) or 0,
            q = (p.errcode == 0) and 1 or 0,
        }
    end
end

-- 对比快照，返回变化的数据表 + 是否有变化
local function diff_data()
    local d = {}
    local any = false

    for _, p in ipairs(store.get_point_values()) do
        local v = (p.values and p.values[1]) or 0
        local q = (p.errcode == 0) and 1 or 0
        local prev = last[p.dev_id] and last[p.dev_id][p.tag]

        if (not prev) or prev.v ~= v or prev.q ~= q then
            any = true
            last[p.dev_id] = last[p.dev_id] or {}
            last[p.dev_id][p.tag] = { v = v, q = q }

            local ts = p.ts
            if not ts or ts == 0 then ts = os.time() end

            local dev_key = tostring(p.dev_id)
            d[dev_key] = d[dev_key] or {}
            d[dev_key][p.tag] = {
                q = tostring(q),
                t = tostring(ts),
                v = tostring(v),
            }
        end
    end

    return d, any
end

-- ============================================================
-- 三种上报
-- ============================================================
local function send_real(boundary_ts)
    if not store_ready() then return end
    if not time_ok("real") then return end

    local d = build_data(nil, boundary_ts)
    if not has_any(d) then return end

    sender.publish(topics.UP_DATA, up.with_time("real", now_str(boundary_ts), d), 1)
    commit_snapshot()
    log.info("mqtt.report", "real 上报完成", "ti=" .. now_str(boundary_ts))
end

-- set 成功后补发一条 real（协议 2.4 注：iot 收到 setack 不会改自己的实时数据，
-- 需要控制器再发一条格式与 2.1.1 相同的数据；由 down.lua 在确有写入成功时调用）
function report.send_real_after_set()
    if not store_ready() then return end
    if not time_ok("real") then return end

    local now = os.time()
    -- 不做整点对齐：各点用自己最新的采集时间，ti 用当前时间
    local d = build_data(nil, nil)
    if not has_any(d) then return end

    sender.publish(topics.UP_DATA, up.with_time("real", now_str(now), d), 1)
    -- 更新快照，避免同一次写入又被 change 重复上报
    commit_snapshot()
    log.info("mqtt.report", "set 后补发 real", "ti=" .. now_str(now))
end

local function send_change()
    if not store_ready() then return end
    if not time_ok("change") then return end

    local d, any = diff_data()
    if not any then return end

    sender.publish(topics.UP_DATA, up.with_time("change", now_str(), d), 1)
    log.info("mqtt.report", "change 上报完成")
end

local function send_fast()
    if not store_ready() then return end
    if not time_ok("realIndex") then return end

    local d = build_data(fast.targets, nil)
    if not has_any(d) then return end

    sender.publish(topics.UP_DATA, up.with_time("realIndex", now_str(), d), 1)
    log.info("mqtt.report", "realIndex 快速上报")
end

-- ============================================================
-- 对外：indexReal 指令入口（由 down.lua 调用）
-- msg: { t="indexReal", sti=..., du=..., iv=..., d={ dev={ts={...}, mid=...} } }
-- ============================================================
function report.start_index_real(msg)
    if not store_ready() then
        log.warn("mqtt.report", "indexReal store 未就绪")
        return
    end
    if not time_ok("indexReal") then return end

    local du = tonumber(msg.du)
    local iv = tonumber(msg.iv) or 5

    -- 不合法时长：不执行，但按协议仍要回 ack（fail = 请求的全部 tag）
    if du == nil or du < 0 or du > 1800 then
        log.warn("mqtt.report", "indexReal du 非法，不执行", tostring(msg.du))
        for dev_id, body in pairs(msg.d or {}) do
            local fail_tags = body.ts or {}
            sender.publish(topics.UP_CONTROL_ACK,
                ack.build("indexRealAck", dev_id, { fail = fail_tags }, body.mid), 1)
        end
        return
    end

    local iv_sec = IV_IS_SECOND and iv or (iv / 1000)
    if iv_sec < 1 then iv_sec = 1 end

    local targets = {}
    local acks = {}

    for dev_id, body in pairs(msg.d or {}) do
        local did = tonumber(dev_id) or dev_id

        -- ts 缺省 → 该设备全部 tag
        local tags = body.ts
        if not tags or #tags == 0 then
            tags = {}
            for _, p in ipairs(store.get_point_values()) do
                if p.dev_id == did then tags[#tags + 1] = p.tag end
            end
        end

        local ok_tags, not_found = {}, {}
        for _, tag in ipairs(tags) do
            if store.get_reg_by_tag(did, tag) then
                ok_tags[#ok_tags + 1] = tag
            else
                not_found[#not_found + 1] = tag
            end
        end

        if #ok_tags > 0 then
            targets[did] = targets[did] or {}
            for _, tag in ipairs(ok_tags) do targets[did][tag] = true end
        end

        if #not_found > 0 then
            acks[#acks + 1] = { dev = dev_id, mid = body.mid, r = { not_found = not_found } }
        else
            acks[#acks + 1] = { dev = dev_id, mid = body.mid, r = { success = "all" } }
        end
    end

    -- 新指令覆盖旧的快速上报配置（协议：想延长 duration 平台会再发一条）
    fast.targets   = targets
    fast.active    = true
    fast.deadline  = os.time() + du
    fast.iv_sec    = iv_sec
    fast.next_send = os.time()   -- 立即上报一次

    for _, a in ipairs(acks) do
        sender.publish(topics.UP_CONTROL_ACK, ack.build("indexRealAck", a.dev, a.r, a.mid), 1)
    end

    sys.publish(WAKE_TOPIC)      -- 唤醒上报 task 立即执行
    log.info("mqtt.report", "indexReal 启动", "du=" .. du .. "s", "iv=" .. iv_sec .. "s")
end

-- ============================================================
-- 上报主 task
-- ============================================================
local function report_task()
    sys.wait(3000)
    while not store_ready() do
        sys.wait(1000)
    end

    -- 开机先建快照，避免把"首次采集"整体当成变化上报
    commit_snapshot()

    local last_change_check = os.time()
    -- 最近一次已处理的整点（unix 秒）。必须基于当前时钟计算，不能预存未来时间点：
    -- NTP 校时会把时钟从 2000 年瞬间跳到 2026 年，任何"校准前算好的 boundary"
    -- 都会变成过期值，醒来后 now >= boundary 恒成立，导致用 2000 年的时间戳上报。
    local init_period = (tonumber(config.get("upload_interval_min")) or 5) * 60
    if init_period < 60 then init_period = 60 end
    local last_real_ts = os.time() - (os.time() % init_period)

    while true do
        local now = os.time()

        local period_min = tonumber(config.get("upload_interval_min")) or 5
        if period_min < 1 then period_min = 1 end
        local period = period_min * 60

        local change_sec = tonumber(config.get("change_check_sec")) or 5
        if change_sec < 1 then change_sec = 1 end

        -- 下一个整点（对齐到 period 的整数倍）
        local next_boundary = now - (now % period) + period
        -- 下一次变化检测
        local next_change = last_change_check + change_sec
        -- 下一次快速上报
        local next_fast = fast.active and fast.next_send or nil

        local wake_at = next_boundary
        if next_change < wake_at then wake_at = next_change end
        if next_fast and next_fast < wake_at then wake_at = next_fast end

        local wait_ms = (wake_at - now) * 1000
        if wait_ms < 50 then wait_ms = 50 end

        -- 被 indexReal 指令唤醒时会提前返回，下一轮重新计算
        sys.waitUntil(WAKE_TOPIC, wait_ms)

        -- 醒来后用当前时钟重新算整点，绝不使用睡前的值
        now = os.time()
        local cur_boundary = now - (now % period)

        -- 时钟回退（少见）：重置基准，等下一个整点
        if cur_boundary < last_real_ts then
            log.warn("mqtt.report", "检测到时钟回退，重置整点基准",
                     os.date("%Y-%m-%d %H:%M:%S", now))
            last_real_ts = cur_boundary
        end

        -- 整点全量上报（优先执行，避免和 change 在同一秒重复上报）
        local did_real = false
        if cur_boundary > last_real_ts then
            local gap = cur_boundary - last_real_ts
            last_real_ts = cur_boundary

            if gap <= period * 2 then
                -- 正常跨过一个周期
                send_real(cur_boundary)
                did_real = true
            else
                -- 时钟跳变（例如 NTP 校准跨年）：只重新对齐，不发这条假整点
                log.warn("mqtt.report", "时钟跳变，跳过本次整点上报",
                         "gap=" .. gap .. "s",
                         "new_boundary=" .. os.date("%Y-%m-%d %H:%M:%S", cur_boundary))
            end
        end

        -- 快速上报
        if fast.active then
            if now >= fast.next_send then
                send_fast()
                fast.next_send = now + fast.iv_sec
            end
            if now >= fast.deadline then
                fast.active = false
                log.info("mqtt.report", "indexReal 到期，恢复常规上报")
            end
        end

        -- 变化上报
        if now >= last_change_check + change_sec then
            if not did_real then send_change() end
            last_change_check = now
        end
    end
end

sys.taskInit(report_task)

return report
