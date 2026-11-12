--[[
@module  net_watchdog
@summary 网络连接看门狗
@version 1.0
@date    2026.11.12
@usage
监控网络是否"活着"：启动一个看门狗 task，等待其他网络应用模块
（如 MQTT 的心跳 / 发送 / 下行接收）来喂狗。

喂狗方式（任意模块均可调用）：
  sys.publish("FEED_NETWORK_WATCHDOG")

若超时未收到喂狗消息，则延时后执行 rtos.reboot() 软重启。

所有参数直接写死在文件内，不依赖 config。
说明：默认未在 main.lua 中加载，需要时取消注释 require 即可。
]]

-- ============================================================
-- 配置项
-- ============================================================
local WATCHDOG_TIMEOUT_MS      = 300000   -- 5 分钟无喂狗则认为网络挂了
local WATCHDOG_REBOOT_DELAY_MS = 3000     -- 超时后延时多久再重启

local function net_watchdog_task()
    while true do
        -- 等待喂狗消息；超时返回 false，说明网络长时间无活动
        if not sys.waitUntil("FEED_NETWORK_WATCHDOG", WATCHDOG_TIMEOUT_MS) then
            log.error("net_watchdog", "timeout, rebooting...")
            sys.wait(WATCHDOG_REBOOT_DELAY_MS)
            rtos.reboot()
        end
    end
end

sys.taskInit(net_watchdog_task)
