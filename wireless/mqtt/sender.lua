--[[
@module  sender
@summary mqtt 上行数据发送模块（队列 + 串行发送 task）
@version 2.0
@date    2026.11.12
@usage
本文件负责"向一个或多个主题发布 JSON"：
1、其他模块调 sender.publish(topic, payload, qos, cb, cb_para) 把数据放进 send_queue；
   也可以用 sys.publish("SEND_DATA_REQ", {topic=..., payload=..., qos=..., cb=..., cb_para=...})；
   topic 由调用方决定，所以天然支持多上行主题；
2、sender task 一次只发一条，qos>0 要等到 PUBLISH_OK 才发下一条，保证顺序；
   qos0 没有 PUBACK，publish 返回即视为成功，继续发下一条；
3、断线时队列不丢：在途数据退回队首，重连后自动重发；
   同步发送失败最多重试 MAX_RETRY 次，超过才回调失败并丢弃；
4、队列有上限，满了丢最旧的一条并回调失败，避免离线期间无限增长。

本文件的对外接口：
1、sender.publish(topic, payload, qos, cb, cb_para)
2、sender.TASK_NAME：task 名，供 basic.lua 投递 "MQTT_EVENT" 消息

协议确定后，业务模块这样发数据（topic 用 basic.TOPIC_UP 或任意自定义主题）：
  local sender = require "sender"
  local basic  = require "basic"
  sender.publish(basic.TOPIC_UP, json.encode({...}), 1, function(ok)
      log.info("mqtt.send", "publish result", ok)
  end)

注意事项：
1、cb 在 sender task 里执行，回调里不要做耗时/阻塞操作，否则会卡住后续发送；
2、payload 必须是纯 JSON 字符串（服务器按协议解析，不加任何前缀）。
]]

local sender = {}

sender.TASK_NAME = "mqtt_sender"

-- 队列上限：离线期间最多缓存这么多条
local MAX_QUEUE = 64
-- 单条数据同步发送失败的最大重试次数
local MAX_RETRY = 3
-- 有积压但发不出去时的重试间隔（毫秒）
local RETRY_INTERVAL_MS = 1000

-- 发送队列，元素结构：
-- {topic=string, payload=string, qos=number, cb=function|nil, cb_para=any, retry=number, msgid=number}
local send_queue = {}

-- 正在等待 PUBACK 的数据项（qos>0 时有效；qos0 不进这里）
local send_item

-- 执行发送结果回调
local function finish_item(item, result)
    if item and item.cb then
        item.cb(result, item.cb_para)
    end
end

-- 按顺序发送队列中的数据
-- 返回正在等待 PUBACK 的数据项；没有在途项时返回 nil
local function publish_item(mqtt_client)
    while #send_queue > 0 do
        local item = table.remove(send_queue, 1)
        local result = mqtt_client:publish(item.topic, item.payload, item.qos)

        if result then
            if item.qos == 0 then
                -- qos0 没有 PUBACK，publish 返回即成功，直接继续下一条
                finish_item(item, true)
                sys.publish("FEED_NETWORK_WATCHDOG")
            else
                -- qos1/2：result 是 message id，等 "sent"/PUBLISH_OK 再推进
                item.msgid = result
                return item
            end
        else
            -- 同步发送失败：有限次重试，超过则回调失败并丢弃
            item.retry = (item.retry or 0) + 1
            if item.retry >= MAX_RETRY then
                log.error("mqtt.send", "publish failed, drop", item.topic, item.retry)
                finish_item(item, false)
            else
                -- 放回队首，等 RETRY_INTERVAL_MS 后的超时重试，本轮先停下避免忙等
                table.insert(send_queue, 1, item)
                return nil
            end
        end
    end
end

-- sender task：队列有数据就发，一次一条
local function sender_task_func()
    local mqtt_client
    local msg

    while true do
        -- 有积压却发不出去时用短超时定期重试，空闲时长时间阻塞
        local timeout = 60000
        if mqtt_client and not send_item and #send_queue > 0 then
            timeout = RETRY_INTERVAL_MS
        end

        msg = sys.waitMsg(sender.TASK_NAME, "MQTT_EVENT", timeout)

        if not msg then
            -- 超时：处理"同步发送失败后等待重试"的情况
            if mqtt_client and not send_item and #send_queue > 0 then
                send_item = publish_item(mqtt_client)
            end

        elseif msg[2] == "CONNECT_OK" then
            mqtt_client = msg[3]
            send_item = publish_item(mqtt_client)

        elseif msg[2] == "PUBLISH_REQ" then
            if mqtt_client and not send_item and #send_queue > 0 then
                send_item = publish_item(mqtt_client)
            end

        elseif msg[2] == "PUBLISH_OK" then
            -- 只有存在在途项且 message id 对得上才算成功；
            -- qos0 也可能上报 "sent"，此时没有在途项，直接忽略
            if send_item then
                if send_item.msgid == nil or msg[3] == nil or send_item.msgid == msg[3] then
                    finish_item(send_item, true)
                    sys.publish("FEED_NETWORK_WATCHDOG")
                    send_item = nil
                    if mqtt_client then
                        send_item = publish_item(mqtt_client)
                    end
                else
                    log.warn("mqtt.send", "unexpected PUBLISH_OK", msg[3], "expect", send_item.msgid)
                end
            end

        elseif msg[2] == "DISCONNECTED" then
            -- 断线不清空队列：在途数据退回队首，重连后重发
            mqtt_client = nil
            if send_item then
                table.insert(send_queue, 1, send_item)
                send_item = nil
            end
            log.warn("mqtt.send", "disconnected, keep", #send_queue, "item(s) for retry")
        end
    end
end

-- 对外发送接口：topic 由调用方指定，支持多上行主题
function sender.publish(topic, payload, qos, cb, cb_para)
    if type(topic) ~= "string" or topic == "" or type(payload) ~= "string" then
        log.error("mqtt.send", "invalid topic or payload")
        if cb then
            cb(false, cb_para)
        end
        return false
    end

    if qos ~= 0 and qos ~= 1 and qos ~= 2 then
        qos = 0
    end

    -- 队列满：丢最旧的一条并回调失败
    if #send_queue >= MAX_QUEUE then
        local dropped = table.remove(send_queue, 1)
        log.warn("mqtt.send", "queue full, drop oldest", dropped.topic)
        finish_item(dropped, false)
    end

    send_queue[#send_queue + 1] = {
        topic = topic,
        payload = payload,
        qos = qos,
        cb = cb,
        cb_para = cb_para,
    }
    sys.sendMsg(sender.TASK_NAME, "MQTT_EVENT", "PUBLISH_REQ")
    return true
end

-- 消息方式入队：sys.publish("SEND_DATA_REQ", {...})
sys.subscribe("SEND_DATA_REQ", function(req)
    if type(req) ~= "table" then
        log.error("mqtt.send", "SEND_DATA_REQ need table param")
        return
    end
    sender.publish(req.topic, req.payload, req.qos, req.cb, req.cb_para)
end)

sys.taskInitEx(sender_task_func, sender.TASK_NAME)

return sender
