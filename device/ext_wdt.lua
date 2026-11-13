--[[
@module  ext_wdt
@summary Air153C 外部硬件看门狗喂狗模块
@version 1.3
@date    2026.11.12
@usage
本文件为 Air153C 外部硬件看门狗的喂狗模块，核心业务逻辑为：
1、启动时初始化 Air153C 的 WTDOG 引脚（本板接在 GPIO28）；
2、启动一个 task，按固定间隔在 WTDOG 引脚上产生一个有效喂狗脉冲；
3、如果本 task 因脚本跑飞/死循环/异常无法继续喂狗，
   外部看门狗芯片超时后会直接硬件复位整机，起到兜底复位作用。

Air153C 要点（来源：Air153C 看门狗芯片设计手册 V1.4）：
- 上电即工作，无需启动指令
- 超时时间固定：3.8V 下 240s，3.3V 下 283s（受电压影响）
- 喂狗脉冲宽度必须 > 200ms，否则芯片当毛刺忽略
- 喂狗间隔必须 < 超时时间，推荐 ≤ 150s
- 1 秒内连续 2 个喂狗脉冲 → 立即强制复位（防误触发）

扩展库 air153C_wtd 属于官方已停止维护的老库，不在 Luatools 的默认 lib 里，
所以优先用扩展库（带脉冲宽度参数），没有时用下面的本地 GPIO 实现兜底，
两者喂狗脉冲默认都是 250ms（满足 > 200ms 要求并留余量）。

本文件没有对外接口，在 main.lua 中 require "ext_wdt" 即自动运行。
]]

-- ============ 参数配置（按需修改） ============
local EXT_WDT_PIN = 28                   -- 外部看门狗 WTDOG 引脚（本板为 GPIO28）
-- 喂狗间隔（毫秒）：手册推荐 ≤ 150s，这里取 120s，给 240s 超时留出足够余量
local EXT_WDT_FEED_INTERVAL_MS = 120000

-- 喂狗脉冲宽度（毫秒）：Air153C 要求 > 200ms，这里给 250ms 留余量
-- 手册描述有矛盾（"高脉冲喂狗" vs "由高变低时重置"），但脉冲宽度 > 200ms 是硬性要求
local FEED_PULSE_MS = 250
 
-- 本地 GPIO 喂狗实现（扩展库缺失时使用）
-- 与 air153C_wtd 扩展库行为一致：init 设初始低电平，喂狗时拉高→保持 250ms→拉低
-- 芯片在拉低那一瞬间（由高变低下降沿）重置超时计时器
local local_wtd = {}

function local_wtd.init(pin)
    gpio.setup(pin, 0)      -- 初始低电平
end

function local_wtd.feed_dog(pin)
    gpio.set(pin, 1)        -- 拉高
    sys.wait(FEED_PULSE_MS) -- 保持高电平 250ms
    gpio.set(pin, 0)        -- 拉低，产生下降沿，触发芯片重置计时器
end

-- 喂狗任务处理函数
local function ext_wdt_task_func()
    -- 优先使用扩展库；不存在时回退到本地 GPIO 实现
    local wtd = air153C_wtd
    local use_lib = (wtd ~= nil)
    if not use_lib then
        wtd = local_wtd
    end

    -- 初始化 WTDOG 引脚
    wtd.init(EXT_WDT_PIN)
    log.info("ext_wdt", "Air153C 外部看门狗已初始化，引脚", EXT_WDT_PIN,
             "喂狗间隔", EXT_WDT_FEED_INTERVAL_MS .. "ms",
             "脉冲宽度", FEED_PULSE_MS .. "ms",
             "实现方式", use_lib and "air153C_wtd 扩展库" or "本地 GPIO")

    -- 循环外一次性定好喂狗动作，主循环里不再每次判断用哪种实现
    local feed
    if use_lib then
        feed = function()
            wtd.feed_dog(EXT_WDT_PIN, FEED_PULSE_MS)
        end
    else
        feed = function()
            wtd.feed_dog(EXT_WDT_PIN)
        end
    end

    local feed_count = 0
    local ok, err = pcall(function()
        while true do
            feed_count = feed_count + 1
            -- 喂狗：产生一个宽度 250ms 的喂狗脉冲（正常运行时不打日志，避免刷屏）
            feed()
            -- 间隔必须小于 Air153C 的溢出时间（240 秒），否则会被硬件复位
            sys.wait(EXT_WDT_FEED_INTERVAL_MS)
        end
    end)

    -- 任何内部错误都 catch 住，打出来，方便判断"喂狗 task 是否在跑"
    if not ok then
        log.error("ext_wdt/feed", "喂狗 task 异常退出，已喂狗", feed_count, "次，错误:", err)
    end
end

-- 创建并且启动喂狗 task
sys.taskInit(ext_wdt_task_func)
