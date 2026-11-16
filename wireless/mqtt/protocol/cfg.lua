--[[
@module  cfg
@summary 网关自身参数模型：把网关当成一台"虚拟设备"，UID 作为设备 id
@version 1.0
@date    2026.11.16
@usage
服务端对 /s2/${sn} 发 call/set，payload 结构与设备完全相同：
  { "t":"call", "d":{ "03230619179356C9":{ "ts":["u1_baudrate"], "mid":123 } } }

区别只在网关内部：设备 set 走 485 写穿透，参数 set 走 config.lua 落盘。

当前进度：
  已实现  call —— 读参数 + 读状态（含 sys_need_reboot / sys_last_error）
  已实现  set  —— 改参数 + 落盘 + setack + change 上报 + sys_need_reboot 标记
  未实现  动作 —— sys_action（reboot / factoryReset）

参数 key 规范：
  沿用 data/config.lua 的扁平 key（u1_baudrate / upload_interval_min ...），不嵌套。

值类型：
  上行一律字符串（与协议里 v 一致）；下行 tonumber 兜底，数字和字符串都能写。
]]

local topics = require "topics"
local up     = require "up"
local ack    = require "ack"
local sender = require "sender"
local config = require "config"

local cfg = {}

-- ============================================================
-- 参数注册表：白名单 + 校验规则
-- type          number / string / bool
-- min / max     仅 number 有效
-- enum          仅 string 有效
-- requires_reboot  写入后必须重启才生效（内部元数据，不是可读 tag）
-- ============================================================
local REG = {
    u1_baudrate = { type = "number", min = 1200,  max = 115200, requires_reboot = true },
    u1_databits = { type = "number", min = 5,     max = 8,      requires_reboot = true },
    u1_stopbits = { type = "number", min = 1,     max = 2,      requires_reboot = true },
    u1_parity   = { type = "string", enum = { N = true, E = true, O = true }, requires_reboot = true },

    u2_baudrate = { type = "number", min = 1200,  max = 115200, requires_reboot = true },
    u2_databits = { type = "number", min = 5,     max = 8,      requires_reboot = true },
    u2_stopbits = { type = "number", min = 1,     max = 2,      requires_reboot = true },
    u2_parity   = { type = "string", enum = { N = true, E = true, O = true }, requires_reboot = true },

    upload_interval_min = { type = "number", min = 1,  max = 60 },
    change_check_sec    = { type = "number", min = 1,  max = 60 },
    write_through_en    = { type = "bool" },
}

-- 全量读取时的输出顺序（Lua 表无序，固定顺序方便平台对比）
local PARAM_ORDER = {
    "u1_baudrate", "u1_databits", "u1_stopbits", "u1_parity",
    "u2_baudrate", "u2_databits", "u2_stopbits", "u2_parity",
    "upload_interval_min", "change_check_sec", "write_through_en",
}

-- 只读状态 key（不落盘，每次读都现取）
local STATUS_ORDER = {
    "model", "fw", "sn", "imei", "iccid", "csq", "ip", "uptime_s",
    "sys_need_reboot", "sys_last_error",
}

-- 只读 key 白名单：被写入时按"存在但不可写"处理（fail），而不是 not_found
local READONLY = {
    model = true, fw = true, sn = true, imei = true, iccid = true,
    csq = true, ip = true, uptime_s = true,
    sys_need_reboot = true, sys_last_error = true,
}

-- ============================================================
-- 运行时状态
-- ============================================================
-- 参数"生效时间"：本次启动时刻。上电时还没校时，读取时若发现是 2000 年
-- 就改用当前时间，避免把 946684800 这种假时间发给平台。
local TIME_VALID_MIN = 1600000000
local boot_ts = os.time()

-- 参数最后写入时间（不落盘，重启后回到 boot_ts）
local mtime = {}

-- 有待重启生效的参数（重启后自然清零）
local pending_reboot = false
-- 最近一次失败原因（readonly / invalid_value / flash_fail）
local last_error = ""

-- 参数时间：优先用写入时间；未写过或时间非法时退回当前时间
local function param_ts(key)
    local t = mtime[key] or boot_ts
    if t < TIME_VALID_MIN then
        local now = os.time()
        if now >= TIME_VALID_MIN then return now end
    end
    return t
end

-- ============================================================
-- 只读状态取值
-- ============================================================
local function status_get(key)
    if key == "model" then
        return "D700Tm_3RS485"
    elseif key == "fw" then
        return tostring(VERSION or "unknown")
    elseif key == "sn" then
        return topics.SN
    elseif key == "imei" then
        return tostring((mobile and mobile.imei()) or "")
    elseif key == "iccid" then
        return tostring((mobile and mobile.iccid()) or "")
    elseif key == "csq" then
        return tostring((mobile and mobile.csq()) or 0)
    elseif key == "ip" then
        return tostring(socket.localIP(socket.LWIP_GP) or "0.0.0.0")
    elseif key == "uptime_s" then
        return tostring(math.floor((mcu.ticks and mcu.ticks() or 0) / 1000))
    elseif key == "sys_need_reboot" then
        return pending_reboot and "1" or "0"
    elseif key == "sys_last_error" then
        return last_error
    end
    return nil
end

-- ============================================================
-- 单个 tag 组装成 { q, t, v }（协议格式，值一律字符串）
-- 参数：生效时间 = 最后写入时间，未写过用本次启动时刻
-- 状态：采集时间 = 读取时刻
-- ============================================================
local function tag_of(key)
    if REG[key] then
        return {
            q = "1",
            t = tostring(param_ts(key)),
            v = tostring(config.get(key)),
        }
    end

    if status_get(key) ~= nil then
        return {
            q = "1",
            t = tostring(os.time()),
            v = status_get(key),
        }
    end

    return nil
end

-- ============================================================
-- 对外：call 读参数/状态（由 down.lua 调用）
-- body.ts 缺省或空数组 → 返回全部参数 + 全部状态
-- ============================================================
function cfg.on_call(dev_key, body)
    local keys = body.ts
    if not keys or #keys == 0 then
        keys = {}
        for _, k in ipairs(PARAM_ORDER)  do keys[#keys + 1] = k end
        for _, k in ipairs(STATUS_ORDER) do keys[#keys + 1] = k end
    end

    local result = {}
    for _, key in ipairs(keys) do
        local item = tag_of(key)
        if item then
            result[key] = item
        else
            -- 与设备 call 一致：拿不到的点位按质量差处理，不破坏 callack 结构
            log.warn("mqtt.cfg", "call 未知参数", key)
            result[key] = { q = "0", t = tostring(os.time()), v = "0" }
        end
    end

    if body.mid ~= nil then result.mid = body.mid end

    local payload = up.with_time("callack", os.date("%Y-%m-%d %H:%M:%S"), { [dev_key] = result })
    sender.publish(topics.UP_CFG, payload, 1)
    log.info("mqtt.cfg", "callack 已发送", "dev=" .. dev_key, "count=" .. #keys)
end

-- ============================================================
-- 参数校验：返回 转换后的值, 错误码（错误码为 nil 表示通过）
-- ============================================================
local function validate(meta, raw)
    if meta.type == "number" then
        local n = tonumber(raw)
        if n == nil then return nil, "invalid_value" end
        if math.floor(n) ~= n then return nil, "invalid_value" end   -- 本文件所有 number 参数都是整数
        if n < meta.min or n > meta.max then return nil, "invalid_value" end
        return n, nil

    elseif meta.type == "string" then
        local s = tostring(raw)
        if meta.enum and not meta.enum[s] then return nil, "invalid_value" end
        return s, nil

    elseif meta.type == "bool" then
        if raw == true  or raw == "1" or raw == 1 then return true,  nil end
        if raw == false or raw == "0" or raw == 0 then return false, nil end
        return nil, "invalid_value"
    end

    return nil, "invalid_value"
end

-- ============================================================
-- 对外：set 改参数（由 down.lua 调用）
-- 规则与设备 set 一致：逐项独立，失败的进 fail / not_found，不影响其它项
-- 写成功后：先回 setack，再发一条 change（只含真正变化的 tag）
-- ============================================================
function cfg.on_set(dev_key, body)
    local now = os.time()
    local changed = {}          -- tag -> 新值字符串
    local fail_tags = {}
    local not_found_tags = {}
    local reboot_before = pending_reboot

    for tag, raw in pairs(body) do
        if tag ~= "mid" then
            local meta = REG[tag]
            if meta then
                local val, code = validate(meta, raw)
                if code ~= nil then
                    fail_tags[#fail_tags + 1] = tag
                    last_error = code
                    log.warn("mqtt.cfg", "set 值非法", tag, tostring(raw), code)
                else
                    local old = config.get(tag)
                    config.set(tag, val)
                    mtime[tag] = now
                    if tostring(old) ~= tostring(val) then
                        changed[tag] = tostring(val)
                    end
                    if meta.requires_reboot then pending_reboot = true end
                    log.info("mqtt.cfg", "set 成功", tag, tostring(old) .. " -> " .. tostring(val))
                end

            elseif READONLY[tag] then
                fail_tags[#fail_tags + 1] = tag
                last_error = "readonly"
                log.warn("mqtt.cfg", "set 只读项", tag)

            else
                not_found_tags[#not_found_tags + 1] = tag
                log.warn("mqtt.cfg", "set 未知参数", tag)
            end
        end
    end

    -- 本次写入把"待重启"从 0 翻到 1：作为一条状态变化一并上报
    local reboot_flipped = (pending_reboot and not reboot_before)
    if reboot_flipped then
        mtime["sys_need_reboot"] = now
    end

    -- 1. 先回 setack
    local r
    if #fail_tags == 0 and #not_found_tags == 0 then
        r = { success = "all" }
    else
        r = {}
        if #fail_tags > 0 then r.fail = fail_tags end
        if #not_found_tags > 0 then r.not_found = not_found_tags end
    end
    sender.publish(topics.UP_CFG, ack.build("setack", dev_key, r, body.mid), 1)
    log.info("mqtt.cfg", "setack 已发送", "dev=" .. dev_key,
             "success=" .. tostring(#fail_tags == 0 and #not_found_tags == 0),
             "fail=" .. #fail_tags, "not_found=" .. #not_found_tags)

    -- 2. 再发 change（只含变化的参数；无变化则不发）
    local d = {}
    local n = 0
    for tag, v in pairs(changed) do
        d[tag] = { q = "1", t = tostring(mtime[tag] or now), v = v }
        n = n + 1
    end
    if reboot_flipped then
        d["sys_need_reboot"] = { q = "1", t = tostring(now), v = "1" }
        n = n + 1
    end

    if n > 0 then
        local payload = up.with_time("change", os.date("%Y-%m-%d %H:%M:%S"), { [dev_key] = d })
        sender.publish(topics.UP_CFG, payload, 1)
        log.info("mqtt.cfg", "change 已发送", "count=" .. n)
    end
end

return cfg
