--[[
@module  sntp
@summary NTP 网络对时模块
@version 1.0
@date    2026.11.15
@usage
1、等待网络 IP_READY 后发起 NTP 对时（socket.sntp 为核心库，无需 require）；
2、同步成功 1 小时后重新同步，失败 10 秒后重试；
3、同步成功后 os.time() / os.date() 即为真实时间，供上行报文的 ti/t 字段使用。

本文件没有对外接口，require 即自动运行。
注意：
1、NTP 同步前 os.time() 拿到的是模组 RTC 默认时间（2000-01-01），不可信；
2、report.lua 里有时间有效性门限，未同步前不会发出时间戳错误的上报。
]]

local function sntp_task_func()
    while true do
        -- 等默认网卡就绪（1 秒超时轮询，兼容多网卡切换时序）
        while not socket.adapter(socket.dft()) do
            log.warn("sntp", "wait IP_READY", socket.dft())
            sys.waitUntil("IP_READY", 1000)
        end

        -- 发起 NTP 对时
        socket.sntp()

        -- 等对时结果，30 秒超时；通常几百毫秒就能成功
        local ret = sys.waitUntil("NTP_UPDATE", 30000)

        if ret then
            log.info("sntp", "时间同步成功", os.date("%Y-%m-%d %H:%M:%S"))
            -- 正常使用 1 小时同步一次足够
            sys.wait(3600000)
        else
            log.warn("sntp", "时间同步失败，10 秒后重试")
            sys.wait(10000)
        end
    end
end

sys.taskInit(sntp_task_func)
