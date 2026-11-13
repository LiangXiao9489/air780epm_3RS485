--[[
@module  down
@summary MQTT 下行 JSON 解析 + 按 topic/type 分发（唯一入口：dispatch）
@version 1.0
@date    2026.11.13
@usage
receiver.lua 在 "recv" 事件回调里拿到 topic 和 payload 后，
只需要调一行 down.dispatch(topic, payload)，down 内部会：
  1. 按 topic 找到对应的 handler 表
  2. json.decode payload 得到 msg
  3. 按 msg.t 找到对应的 type handler
  4. handler 回调里 sys.taskInit 独立 task 处理（不阻塞 receiver 回调）

两个下行 topic 各自的 type：
  /s/${sn}    → call（查询）、set（写入）
  /scr/${sn}  → indexReal（快速上传）、his（历史数据召回）、ctr（采集点控制）

handler 回调签名：function(msg)  msg 是 decode 后的完整表

扩展方式：
  新增下行 topic → TOPIC_HANDLERS 加一行 { [topics.SUB_XXX] = { type=handler, ... } }
  新增 type     → 对应 handler 表里加一行 handlers.type = function(msg) ... end
]]

local topics = require "topics"
local down = {}

-- ============================================================
-- handler 注册表：每个下行 topic 一张表，key = type, value = 回调
-- handler 回调里用 sys.taskInit 起独立 task，不阻塞 receiver
-- ============================================================
local TOPIC_HANDLERS = {
    -- /s/${sn}：主业务下行
    [topics.SUB_DATA] = {
        call = function(msg)
            --  TODO：接入 store 查询缓存 → up.with_time("callack", ...) → sender
            log.info("mqtt.down", "call 查询", json.encode(msg.d))
        end,

        set = function(msg)
            --  TODO：写穿透热泵 → 更新 store → ack.build("setack", ...) → sender
            log.info("mqtt.down", "set 写入", json.encode(msg.d))
        end,
    },

    -- /scr/${sn}：控制下行
    [topics.SUB_CONTROL] = {
        indexReal = function(msg)
            --  TODO：进入快速上传模式（改 store 上报频率或单独 task）
            log.info("mqtt.down", "indexReal 快速上传",
                     "sti=" .. tostring(msg.sti),
                     "du=" .. tostring(msg.du),
                     "iv=" .. tostring(msg.iv))
        end,

        his = function(msg)
            --  TODO：历史数据召回（从本地历史存储读 → UP_HISTORY topic 上报）
            log.info("mqtt.down", "his 历史召回", json.encode(msg.d))
        end,

        ctr = function(msg)
            --  TODO：采集点控制（open/close 上报开关）
            log.info("mqtt.down", "ctr 控制", json.encode(msg.d))
        end,
    },
}

-- ============================================================
-- 对外唯一入口
-- ============================================================
function down.dispatch(topic, payload)
    -- 1. 按 topic 找 handler 表
    local handlers = TOPIC_HANDLERS[topic]
    if not handlers then
        log.warn("mqtt.down", "无 handler 的 topic", topic)
        return false
    end

    -- 2. json.decode
    local ok, msg = pcall(json.decode, payload)
    if not ok or type(msg) ~= "table" then
        log.warn("mqtt.down", "json decode 失败", payload)
        return false
    end

    -- 3. 按 type 找 handler
    local handler = handlers[msg.t]
    if not handler then
        log.warn("mqtt.down", "未知 type", msg.t, "topic=", topic)
        return false
    end

    -- 4. 执行 handler（handler 里自己起独立 task，这里同步调用完就返回）
    handler(msg)
    return true
end

return down
