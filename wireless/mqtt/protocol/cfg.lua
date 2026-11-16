--[[
@module  cfg
@summary 网关自身参数模型：把网关当成一台"虚拟设备"，UID 作为设备 id
@version 1.0
@date    2026.11.16
@usage
服务端对 /s2/${sn} 发 call/set，payload 结构与设备完全相同：
  { "t":"call", "d":{ "03230619179356C9":{ "ts":["u1_baudrate"], "mid":123 } } }

区别只在网关内部：设备 set 走 485 写穿透，参数 set 走 config.lua 落盘。

当前进度（第一步）：
  已实现  call —— 读参数 + 读基础状态
  未实现  set  —— 改参数、change 上报、sys_need_reboot
  未实现  动作 —— sys_action（reboot / factoryReset）

参数 key 规范：
  沿用 data/config.lua 的扁平 key（u1_baudrate / upload_interval_min ...），不嵌套。

值类型：
  上行一律字符串（与协议里 v 一致）；下行 tonumber 兜底，数字和字符串都能写。
]]

local topics = require "topics"
local up     = require "up"
local sender = require "sender"
local config = require "config"

local cfg = {}

-- ============================================================
-- 参数注册表：白名单 + 校验规则
-- type          number / string / bool
-- min / max     仅 number 有效
-- enum          仅 string 有效
-- need_reboot   写入后必须重启才生效
-- ============================================================
local REG = {
    u1_baudrate = { type = "number", min = 1200,  max = 115200, need_reboot = true },
    u1_databits = { type = "number", min = 5,     max = 8,      need_reboot = true },
    u1_stopbits = { type = "number", min = 1,     max = 2,      need_reboot = true },
    u1_parity   = { type = "string", enum = { N = true, E = true, O = true }, need_reboot = true },

    u2_baudrate = { type = "number", min = 1200,  max = 115200, need_reboot = true },
    u2_databits = { type = "number", min = 5,     max = 8,      need_reboot = true },
    u2_stopbits = { type = "number", min = 1,     max = 2,      need_reboot = true },
    u2_parity   = { type = "string", enum = { N = true, E = true, O = true }, need_reboot = true },

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
}

-- 参数"生效时间"：本次启动时刻，写入成功后（第二步）会更新成写入时间
local boot_ts = os.time()

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
    end
    return nil
end

-- ============================================================
-- 单个 tag 组装成 { q, t, v }（协议格式，值一律字符串）
-- 参数：生效时间 = 本次启动时刻（第二步写入后会更新）
-- 状态：采集时间 = 读取时刻
-- ============================================================
local function tag_of(key)
    if REG[key] then
        return {
            q = "1",
            t = tostring(boot_ts),
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

return cfg
