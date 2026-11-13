--[[
@module  basic
@summary mqtt client 主功能模块（建链 / 订阅 / 断线重连调度）
@version 2.0
@date    2026.11.12
@usage
本文件是 mqtt 应用的总调度，核心业务逻辑：
1、创建 mqtt client，连接 broker（地址、端口、账密、主题全部写死在本文件顶部）；
2、连接成功后按 SUB_TOPICS 表批量订阅（当前 1 个下行主题，加一行即可扩展多个）；
3、把 broker 事件翻译成内部 "MQTT_EVENT" 消息分发给各 task：
   - "CONNECT" / "SUBSCRIBE" / "UNSUBSCRIBE" / "DISCONNECTED" / "ERROR" 给自己；
   - "PUBLISH_OK" 给 sender task，用于串行推进发送队列；
   - "recv" 交给 receiver.proc 入队，由 receiver 自己的 task 慢慢处理；
   - "pong" 喂网络看门狗；
4、任何异常（建链失败、鉴权失败、订阅失败、被动断开）都走统一异常出口：
   清队列 → 通知 sender 断开 → 关闭 client → 退避等待 → 重新建链。

本文件没有对外接口，main.lua 里 require "basic" 即可；require 时自动启动 task。
另外导出 basic.TOPIC_UP / basic.TOPIC_DOWN，方便其他模块知道默认主题。

注意：
1、CONNACK 有独立超时（CONNACK_TIMEOUT_MS），broker 不回包不会让任务永久挂死；
2、重连采用 5s 起步、翻倍、30s 封顶的退避，订阅一直被拒也不会高频刷 broker；
3、keepalive 设 60s，小于网络看门狗（5 分钟）的一半，偶发丢一次 pong 不会触发重启。
]]

-- 下行数据处理模块（自带解析 task）
local receiver = require "receiver"
-- 上行发送模块（自带发送 task + 队列）
local sender = require "sender"

-- ============================================================
-- 部署参数：按现场写死
-- ============================================================
local SERVER_ADDR   = "114.251.165.201"
local SERVER_PORT   = 39116
local USERNAME      = "" --"mqtt"
local PASSWORD      = "" --"ZHNY@[mqtt]"
local CLEAN_SESSION = true

-- 无卡/模组未注册时 imei() 可能返回 nil 或空串，用固定值兜底，避免多个设备挤到同一个 topic
local IMEI = (mobile and mobile.imei()) or ""
if IMEI == "" then
    IMEI = "DEV0001"
end
local CLIENT_ID = "mqtt_" .. IMEI

-- 上行主题：当前 1 个。以后要多个，直接用各自的 topic 调 sender.publish 即可，
-- 本文件不用改（sender 按调用方传入的 topic 发送）。
local TOPIC_UP = "feiyiPub/" .. IMEI

-- 下行主题：当前 1 个。以后要多个，往下面 SUB_TOPICS 里加一行。
local TOPIC_DOWN = "feiyiSub/" .. IMEI

-- 订阅表：[topic] = qos，支持多主题
local SUB_TOPICS = {
    [TOPIC_DOWN] = 0,
}

-- ============================================================
-- 连接行为参数
-- ============================================================
local KEEPALIVE_SEC        = 60       -- 心跳间隔（秒）
local CONNACK_TIMEOUT_MS   = 30000    -- 等 CONNACK 的超时，防永久挂死
local RECONNECT_DELAY_MIN  = 5000     -- 重连退避起点（毫秒）
local RECONNECT_DELAY_MAX  = 30000    -- 重连退避上限（毫秒）

-- mqtt_main 的任务名（与 sender / receiver 解耦，不再复用 sender 的前缀）
local TASK_NAME = "mqtt_main"

-- 事件回调原始日志开关：排查问题时打开
local EVENT_LOG_ENABLE = false

-- mqtt client 事件回调（运行在 mqtt/socket 的回调上下文，必须保持轻量）
local function mqtt_client_event_cbfunc(mqtt_client, event, data, payload, metas)
    if EVENT_LOG_ENABLE then
        log.info("mqtt.main", event, data, payload)
    end

    -- 连接成功：发给 main task，同时按表订阅全部下行主题
    if event == "conack" then
        sys.sendMsg(TASK_NAME, "MQTT_EVENT", "CONNECT", true)
        if not mqtt_client:subscribe(SUB_TOPICS) then
            sys.sendMsg(TASK_NAME, "MQTT_EVENT", "SUBSCRIBE", false, -1)
        end

    -- 订阅结果：data=true 成功（payload 为 qos），false 失败（payload 为失败码，一般 0x80）
    elseif event == "suback" then
        sys.sendMsg(TASK_NAME, "MQTT_EVENT", "SUBSCRIBE", data, payload)

    -- 取消订阅成功
    elseif event == "unsuback" then
        sys.sendMsg(TASK_NAME, "MQTT_EVENT", "UNSUBSCRIBE", true)

    -- 收到下行 publish：只入队，不在这里解析
    elseif event == "recv" then
        receiver.proc(data, payload, metas)

    -- publish 成功：通知 sender 推进队列
    -- 注意：qos0 不产生该事件，sender 内部对 qos0 是"发布即成功"
    elseif event == "sent" then
        sys.sendMsg(sender.TASK_NAME, "MQTT_EVENT", "PUBLISH_OK", data)

    -- broker 断开连接
    elseif event == "disconnect" then
        sys.sendMsg(TASK_NAME, "MQTT_EVENT", "DISCONNECTED", false)

    -- 收到心跳应答：喂网络看门狗
    elseif event == "pong" then
        sys.publish("FEED_NETWORK_WATCHDOG")

    -- 严重异常：data 为 "connect"/"tx"/"conack"/"other"，
    -- 其中 conack 失败时 payload 是鉴权失败码（0x04 用户名错 / 0x05 密码错），要带出去排障
    elseif event == "error" then
        if data == "connect" or data == "conack" then
            sys.sendMsg(TASK_NAME, "MQTT_EVENT", "CONNECT", false, payload)
        else
            sys.sendMsg(TASK_NAME, "MQTT_EVENT", "ERROR", data)
        end
    end
end

-- mqtt main task：负责连接生命周期，不做业务收发
local function mqtt_client_main_task_func()
    local mqtt_client
    local result
    local msg
    local retry_delay = RECONNECT_DELAY_MIN

    while true do
        -- 1. 等默认网卡拿到 IP
        while not socket.adapter(socket.dft()) do
            log.warn("mqtt.main", "wait IP_READY", socket.dft())
            -- 1 秒超时是有意为之：多网卡优先级切换会隐式改默认网卡，
            -- 超时后重新判断 socket.adapter(socket.dft()) 才不会卡在旧网卡上
            sys.waitUntil("IP_READY", 1000)
        end
        log.info("mqtt.main", "recv IP_READY", socket.dft())

        -- 丢弃上一轮残留事件（例如 close 之后才到达的 DISCONNECTED）
        sys.cleanMsg(TASK_NAME)

        -- 2. 建链：create / auth / on / keepalive / connect，任一步失败都走异常出口
        mqtt_client = mqtt.create(nil, SERVER_ADDR, SERVER_PORT)
        if not mqtt_client then
            log.error("mqtt.main", "mqtt.create error")
            goto EXCEPTION_PROC
        end

        result = mqtt_client:auth(CLIENT_ID, USERNAME, PASSWORD, CLEAN_SESSION)
        if not result then
            log.error("mqtt.main", "auth error")
            goto EXCEPTION_PROC
        end

        mqtt_client:on(mqtt_client_event_cbfunc)
        mqtt_client:keepalive(KEEPALIVE_SEC)

        if not mqtt_client:connect() then
            log.error("mqtt.main", "connect error")
            goto EXCEPTION_PROC
        end

        -- 3. 单独等 CONNACK，带超时；收到其它事件（如 error）也视为连接失败
        msg = sys.waitMsg(TASK_NAME, "MQTT_EVENT", CONNACK_TIMEOUT_MS)
        if not msg then
            log.error("mqtt.main", "wait CONNACK timeout", CONNACK_TIMEOUT_MS)
            goto EXCEPTION_PROC
        elseif msg[2] ~= "CONNECT" or not msg[3] then
            log.error("mqtt.main", "connect failed", msg[2], msg[3], msg[4])
            goto EXCEPTION_PROC
        end

        log.info("mqtt.main", "connect success")
        -- 连接成功，退避时间复位
        retry_delay = RECONNECT_DELAY_MIN
        -- 把 client 交给 sender，由它按队列发送
        sys.sendMsg(sender.TASK_NAME, "MQTT_EVENT", "CONNECT_OK", mqtt_client)

        -- 4. 已连接后的常驻事件循环（阻塞等待，不设超时）
        while true do
            msg = sys.waitMsg(TASK_NAME, "MQTT_EVENT")
            log.info("mqtt.main", "event", msg[2], msg[3], msg[4])

            if msg[2] == "SUBSCRIBE" then
                if msg[3] then
                    log.info("mqtt.main", "subscribe success", "qos", msg[4])
                else
                    log.error("mqtt.main", "subscribe failed, code", msg[4])
                    break
                end

            elseif msg[2] == "UNSUBSCRIBE" then
                log.info("mqtt.main", "unsubscribe success")

            elseif msg[2] == "CLOSE" then
                -- 其他模块可发 sys.sendMsg("mqtt_main", "MQTT_EVENT", "CLOSE") 主动断开
                mqtt_client:disconnect()
                sys.wait(1000)
                break

            elseif msg[2] == "DISCONNECTED" then
                log.warn("mqtt.main", "disconnected by peer/network")
                break

            elseif msg[2] == "ERROR" then
                log.error("mqtt.main", "mqtt error", msg[3])
                break

            elseif msg[2] == "CONNECT" then
                -- 连接成功之后再次收到 CONNECT，说明状态已经不同步，重连一次
                log.warn("mqtt.main", "unexpected CONNECT event")
                break
            end
        end

        ::EXCEPTION_PROC::

        -- 5. 异常出口：清残留事件、通知 sender 断开、释放 client、退避后重连
        sys.cleanMsg(TASK_NAME)
        sys.sendMsg(sender.TASK_NAME, "MQTT_EVENT", "DISCONNECTED")

        if mqtt_client then
            mqtt_client:close()
            mqtt_client = nil
        end

        log.warn("mqtt.main", "reconnect after", retry_delay, "ms")
        sys.wait(retry_delay)
        retry_delay = retry_delay * 2
        if retry_delay > RECONNECT_DELAY_MAX then
            retry_delay = RECONNECT_DELAY_MAX
        end
    end
end

-- 创建并启动 task
sys.taskInitEx(mqtt_client_main_task_func, TASK_NAME)

return {
    TOPIC_UP   = TOPIC_UP,
    TOPIC_DOWN = TOPIC_DOWN,
}
