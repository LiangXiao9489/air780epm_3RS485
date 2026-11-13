--[[
@module  downlink_uart_lock
@summary u1（下行 RS485）互斥锁：保证一次只有一个活跃的 u1 Modbus 事务
@version 1.0
@date    2026.11.13
@usage
RS485 半双工物理上不支持并发，所有对 u1 的 Modbus 事务（主站轮询 / 从站写穿透
/ 未来 MQTT 写穿透 / 未来更多通道）必须共用这一把锁串行化。

锁范围 = 一个完整的 Modbus 事务（发请求 → 等响应 → 释放）。
中途绝不释放锁，否则响应会被另一个事务截胡。

对外 API：
  lock(owner)     → true/false
  unlock()
  has_waiter()    → true/false    主站轮询据此让出总线给写穿透

超时 800ms，多个等待者按 LuatOS 内部队列唤醒（先到先得近似）。
]]

local _M = {}

-- ============================================================
-- 锁状态
-- ============================================================
local u1_locked = false
local lock_owner = nil
local waiter_count = 0
local LOCK_EVENT = "MODBUS_U1_UNLOCKED"
local LOCK_TIMEOUT_MS = 800

-- 获取锁；owner 仅日志用
function _M.lock(owner)
    local t0 = mcu.ticks()
    local counted = false
    if u1_locked then
        waiter_count = waiter_count + 1
        counted = true
    end
    while u1_locked do
        local remain = LOCK_TIMEOUT_MS - (mcu.ticks() - t0)
        if remain <= 0 then
            if counted then
                waiter_count = waiter_count - 1
            end
            log.warn("downlink_lock", "超时等锁",
                     "当前持有者=" .. tostring(lock_owner),
                     "请求者=" .. tostring(owner))
            return false
        end
        sys.waitUntil(LOCK_EVENT, remain)
    end
    if counted then
        waiter_count = waiter_count - 1
    end
    u1_locked = true
    lock_owner = owner
    return true
end

-- 是否有协程正在等 u1（主站轮询据此让出总线给写穿透）
function _M.has_waiter()
    return waiter_count > 0
end

-- 释放锁
function _M.unlock()
    if not u1_locked then
        log.warn("downlink_lock", "unlock 时未上锁")
        return
    end
    u1_locked = false
    lock_owner = nil
    sys.publish(LOCK_EVENT)
end

return _M
