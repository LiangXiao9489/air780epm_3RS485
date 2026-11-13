--[[
@module  receiver
@summary mqtt 下行数据处理模块（入队 + 独立 task 解析）
@version 2.0
@date    2026.11.12
@usage
本文件负责"一条或多条订阅主题收到下行 JSON 后怎么处理"：
1、mqtt 回调里只做入队（receiver.proc），保证不阻塞 mqtt/socket 上下文；
2、本模块自己的 task 等待 "MQTT_RECV" 消息，醒来后把队列一次取空；
3、当前 JSON 协议未定，只做打印；协议确定后，在下方 TODO 处补 json.decode 和按 cmd 分发。

队列有上限，满时丢最旧的一条并告警，避免服务器狂推导致内存耗尽。

本文件的对外接口有1个：
1、receiver.proc(topic, payload, metas)：由 basic.lua 的 mqtt 事件回调调用。
]]

local receiver = {}

receiver.TASK_NAME = "mqtt_receiver"

-- 队列上限：下行突发时最多缓存这么多条，超出丢最旧
local MAX_QUEUE = 32
-- 单行日志最大长度：超过则分段打印，避免被日志系统截断
local LOG_CHUNK = 256

-- 下行待处理队列，元素结构：{topic=string, payload=string, metas=table}
local recv_queue = {}

-- 计算分段末尾，避免把一个 UTF-8 汉字截成两半
local function chunk_end(text, start, size)
    local stop = start + size - 1
    if stop >= #text then
        return #text
    end
    while stop < #text do
        local b = text:byte(stop + 1)
        -- 0x80~0xBF 是 UTF-8 续字节，说明当前字符还没结束，继续往后吞
        if not b or b < 0x80 or b >= 0xC0 then
            break
        end
        stop = stop + 1
    end
    return stop
end

-- 分段打印，避免超长 JSON 被截断
local function log_payload(topic, text)
    log.info("mqtt.recv", "topic:", topic, "len:", #text)
    local i = 1
    while i <= #text do
        local stop = chunk_end(text, i, LOG_CHUNK)
        log.info("mqtt.recv", text:sub(i, stop))
        i = stop + 1
    end
end

-- 下行处理 task：队列有数据就取出来处理
local function recv_task_func()
    while true do
        -- 60 秒超时兜底，即使通知消息丢了也能把队列里的数据处理掉
        sys.waitMsg(receiver.TASK_NAME, "MQTT_RECV", 60000)

        -- 一次取空，顺手清掉多余的 "MQTT_RECV" 通知，避免空转
        sys.cleanMsg(receiver.TASK_NAME)

        while #recv_queue > 0 do
            local item = table.remove(recv_queue, 1)
            local text = tostring(item.payload or "")

            -- TODO 协议确定后在这里处理：
            --   local ok, msg = pcall(json.decode, text)
            --   按 msg.cmd 分发，需要回执时用 sender.publish(topic, json.encode(ack), qos)
            -- 当前协议未定，先打印代替解析
            log_payload(tostring(item.topic), text)
        end
    end
end

-- 下行数据入口：只入队，不做耗时操作（运行在 mqtt 回调上下文）
function receiver.proc(topic, payload, metas)
    -- 收到任何下行数据都喂一次网络看门狗
    sys.publish("FEED_NETWORK_WATCHDOG")

    if #recv_queue >= MAX_QUEUE then
        table.remove(recv_queue, 1)
        log.warn("mqtt.recv", "queue full, drop oldest")
    end

    recv_queue[#recv_queue + 1] = {topic = topic, payload = payload, metas = metas}
    sys.sendMsg(receiver.TASK_NAME, "MQTT_RECV")
end

sys.taskInitEx(recv_task_func, receiver.TASK_NAME)

return receiver
