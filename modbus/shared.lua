--[[
@module  shared
@summary Modbus 网关共享资源：寄存器缓存 + u1 总线互斥锁
@version 1.0
@date    2026.11.12
@usage
本文件聚合了主站（master）和从站（slave）共享的两部分：

一、寄存器缓存（RAM 存储，双向索引，多从机支持）
   每个 slot 同时存 A 侧 (dev_id, s_addr) 和 B 侧 (dev_id, n_addr)
   - cache_a[dev_id][s_addr] = slot   — 主站轮询更新用
   - cache_b[dev_id][n_addr] = slot   — 上行从站读取用
   对外 API：init / write_by_a / read_by_a / read_by_b / get_reg_by_b
            / get_all_regs / get_regs_by_dev / get_point_values

二、u1 串口互斥锁
   确保一次只有一个活跃的 u1 Modbus 事务（主站轮询 / 从站写穿透）
   对外 API：lock / unlock / has_waiter
]]

local _M = {}

-- ============================================================
-- 自定义错误码（仅作缓存状态标记，永不上总线）
-- ============================================================
_M.ERR_UNINIT = 0x08   -- 未初始化（未采集过）

-- ============================================================
-- 一、寄存器缓存
-- ============================================================
local cache_a = {}        -- cache_a[dev_id][s_addr] = slot
local cache_b = {}        -- cache_b[dev_id][n_addr] = slot
local regs_by_b = {}      -- regs_by_b[dev_id][n_addr] = 完整 reg 配置
local expanded_regs = {}  -- 展开后的完整点表（给主站轮询用）

-- 判断 (dev_id, n_addr) 是否在 cache_b 里
local function has_n_addr(dev_id, n_addr)
    return cache_b[dev_id] and cache_b[dev_id][n_addr] ~= nil
end
_M.has_n_addr = has_n_addr

-- 初始化（从点表自动展开，建 slot + 双向索引）
function _M.init(pt)
    cache_a = {}
    cache_b = {}
    regs_by_b = {}
    expanded_regs = {}

    local slave_dev = pt.meta.slave_dev or {}
    local regs_tpl = pt.regs or {}

    log.info("shared", "开始初始化", "从机数=" .. #slave_dev, "模板寄存器数=" .. #regs_tpl)

    for _, dev_id in ipairs(slave_dev) do
        cache_a[dev_id] = {}
        cache_b[dev_id] = {}
        regs_by_b[dev_id] = {}

        for _, tpl in ipairs(regs_tpl) do
            local reg_type = tpl.reg_type
            local count    = tpl.reg_count or 1

            -- 校验：reg_count 至少为 1
            if type(count) ~= "number" or count < 1 then
                log.error("shared", "点表错误", "dev_id="..dev_id,
                          "tag="..tostring(tpl.tag), "reg_count 非法="..tostring(tpl.reg_count))
                return false
            end
            -- 位类型（线圈/离散）不支持多点
            if (reg_type == 1 or reg_type == 2) and count > 1 then
                log.error("shared", "点表错误", "dev_id="..dev_id,
                          "tag="..tostring(tpl.tag), "线圈/离散输入不支持 reg_count>1")
                return false
            end

            -- 校验：区间不重叠
            for i = 0, count - 1 do
                if cache_a[dev_id][tpl.s_addr + i] then
                    log.error("shared", "点表错误", "dev_id="..dev_id,
                              "s_addr="..(tpl.s_addr + i).." 重复或区间重叠")
                    return false
                end
                if cache_b[dev_id][tpl.n_addr + i] then
                    log.error("shared", "点表错误", "dev_id="..dev_id,
                              "n_addr="..(tpl.n_addr + i).." 重复或区间重叠")
                    return false
                end
            end

            -- 读写权限：离散输入/输入寄存器强制只读
            local rw = tpl.rw or "r"
            if reg_type == 2 or reg_type == 4 then
                rw = "r"
            end

            -- 展开成 count 个 slot
            for i = 0, count - 1 do
                local s_addr = tpl.s_addr + i
                local n_addr = tpl.n_addr + i

                local slot = {
                    dev_id  = dev_id,
                    s_addr  = s_addr,
                    n_addr  = n_addr,
                    data    = 0xFFFF,
                    errcode = _M.ERR_UNINIT,
                }
                cache_a[dev_id][s_addr] = slot
                cache_b[dev_id][n_addr] = slot

                local full_reg = {
                    dev_id       = dev_id,
                    num          = tpl.num,
                    tag          = tpl.tag,
                    s_addr       = s_addr,
                    n_addr       = n_addr,
                    base_s_addr  = tpl.s_addr,
                    base_n_addr  = tpl.n_addr,
                    reg_type     = reg_type,
                    reg_count    = count,
                    group_offset = i,
                    data_type    = tpl.data_type,
                    scale_factor = tpl.scale_factor,
                    rw           = rw,
                    bits         = (i == 0) and tpl.bits or nil,
                }
                regs_by_b[dev_id][n_addr] = full_reg
                expanded_regs[#expanded_regs + 1] = full_reg
            end
        end
    end

    log.info("shared", "初始化完成",
             "总slot数=" .. #expanded_regs,
             "cache_a_devs=" .. #cache_a,
             "cache_b_devs=" .. #cache_b)
    return true
end

-- 主站轮询成功后：按 A 的 (dev_id, s_addr) 更新 slot
function _M.write_by_a(dev_id, s_addr, data, err)
    local slot = cache_a[dev_id] and cache_a[dev_id][s_addr]
    if not slot then
        log.warn("shared", "write_by_a",
                 "dev_id=" .. tostring(dev_id),
                 "s_addr=" .. tostring(s_addr),
                 "slot不存在")
        return false
    end
    slot.data = data
    slot.errcode = err or 0
    return true
end

-- 上行从站读：按 B 的 (dev_id, n_addr) 读 slot
function _M.read_by_b(dev_id, n_addr)
    local slot = cache_b[dev_id] and cache_b[dev_id][n_addr]
    if not slot then
        return nil, 0x02
    end
    return slot.data, slot.errcode
end

-- 按 A 的 (dev_id, s_addr) 读 slot（内部用）
function _M.read_by_a(dev_id, s_addr)
    local slot = cache_a[dev_id] and cache_a[dev_id][s_addr]
    if not slot then return nil, 0x02 end
    return slot.data, slot.errcode
end

-- 上行从站查配置：按 B 的 (dev_id, n_addr) 查完整配置
function _M.get_reg_by_b(dev_id, n_addr)
    if not regs_by_b[dev_id] then return nil end
    return regs_by_b[dev_id][n_addr]
end

-- 主站轮询用：拿到展开后的完整点表
function _M.get_all_regs()
    return expanded_regs
end

-- 按 dev_id 分组取 regs
function _M.get_regs_by_dev(dev_id)
    local result = {}
    for _, r in ipairs(expanded_regs) do
        if r.dev_id == dev_id then
            result[#result + 1] = r
        end
    end
    return result
end

-- 调试用：按「点位」聚合当前所有缓存值
function _M.get_point_values()
    local result = {}
    local seen = {}

    for _, reg in ipairs(expanded_regs) do
        if reg.group_offset == 0 then
            local key = reg.dev_id .. ":" .. reg.base_n_addr
            if not seen[key] then
                seen[key] = true

                local values = {}
                local errcode = 0
                local dev_cache = cache_a[reg.dev_id] or {}
                for i = 0, (reg.reg_count or 1) - 1 do
                    local slot = dev_cache[reg.base_s_addr + i]
                    if slot then
                        values[#values + 1] = slot.data
                        if errcode == 0 and slot.errcode and slot.errcode ~= 0 then
                            errcode = slot.errcode
                        end
                    else
                        values[#values + 1] = nil
                    end
                end

                result[#result + 1] = {
                    tag          = reg.tag,
                    dev_id       = reg.dev_id,
                    reg_type     = reg.reg_type,
                    reg_count    = reg.reg_count or 1,
                    data_type    = reg.data_type,
                    scale_factor = reg.scale_factor,
                    bits         = reg.bits,
                    values       = values,
                    errcode      = errcode,
                }
            end
        end
    end

    return result
end

-- ============================================================
-- 二、u1 串口互斥锁
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
            log.warn("shared.mutex", "超时等锁",
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
        log.warn("shared.mutex", "unlock 时未上锁")
        return
    end
    u1_locked = false
    lock_owner = nil
    sys.publish(LOCK_EVENT)
end

return _M
