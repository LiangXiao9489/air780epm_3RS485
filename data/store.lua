--[[
@module  store
@summary 寄存器缓存层（整个网关共享的数据中枢）
@version 1.0
@date    2026.11.13
@usage
本模块负责"热泵寄存器缓存"的全生命周期管理。

所有对热泵寄存器的读写（主站轮询更新、从站响应上位机、未来 MQTT 读写穿透）
都经过这里，是整个网关唯一的数据源。

每个 slot 同时存 A 侧 (dev_id, s_addr) 和 B 侧 (dev_id, n_addr)：
  - cache_a[dev_id][s_addr] = slot   — 主站轮询更新用
  - cache_b[dev_id][n_addr] = slot   — 上行从站读取用

对外 API：
  init(pt)                           启动时由 master 调用，展开点表建 slot
  write_by_a(dev_id, s_addr, data, err)  主站轮询成功后写缓存
  read_by_b(dev_id, n_addr)          从站读缓存（返回 data, errcode）
  read_by_a(dev_id, s_addr)          按 A 侧地址读（内部调试用）
  get_reg_by_b(dev_id, n_addr)       从站查完整点表配置
  get_all_regs()                     拿到展开后的完整 reg 表（主站轮询用）
  get_regs_by_dev(dev_id)            按从机地址分组取 regs
  has_n_addr(dev_id, n_addr)         判断 B 侧地址是否存在
  get_point_values()                 调试用：按点位聚合所有缓存值

持久化：纯 RAM 存储，重启后由 master 重新轮询热泵填充。
]]

local _M = {}

-- ============================================================
-- 自定义错误码（仅作缓存状态标记，永不上总线）
-- ============================================================
_M.ERR_UNINIT = 0x08   -- 未初始化（未采集过）

-- ============================================================
-- 缓存状态
-- ============================================================
local cache_a = {}        -- cache_a[dev_id][s_addr] = slot
local cache_b = {}        -- cache_b[dev_id][n_addr] = slot
local regs_by_b = {}      -- regs_by_b[dev_id][n_addr] = 完整 reg 配置
local regs_by_tag = {}    -- regs_by_tag[dev_id][tag] = 完整 reg 配置（MQTT 用，tag 是字符串）
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
    regs_by_tag = {}
    expanded_regs = {}

    local slave_dev = pt.meta.slave_dev or {}
    local regs_tpl = pt.regs or {}

    log.info("store", "开始初始化", "从机数=" .. #slave_dev, "模板寄存器数=" .. #regs_tpl)

    for _, dev_id in ipairs(slave_dev) do
        cache_a[dev_id] = {}
        cache_b[dev_id] = {}
        regs_by_b[dev_id] = {}

        for _, tpl in ipairs(regs_tpl) do
            local reg_type = tpl.reg_type
            local count    = tpl.reg_count or 1

            -- 校验：reg_count 至少为 1
            if type(count) ~= "number" or count < 1 then
                log.error("store", "点表错误", "dev_id="..dev_id,
                          "tag="..tostring(tpl.tag), "reg_count 非法="..tostring(tpl.reg_count))
                return false
            end
            -- 位类型（线圈/离散）不支持多点
            if (reg_type == 1 or reg_type == 2) and count > 1 then
                log.error("store", "点表错误", "dev_id="..dev_id,
                          "tag="..tostring(tpl.tag), "线圈/离散输入不支持 reg_count>1")
                return false
            end

            -- 校验：区间不重叠
            for i = 0, count - 1 do
                if cache_a[dev_id][tpl.s_addr + i] then
                    log.error("store", "点表错误", "dev_id="..dev_id,
                              "s_addr="..(tpl.s_addr + i).." 重复或区间重叠")
                    return false
                end
                if cache_b[dev_id][tpl.n_addr + i] then
                    log.error("store", "点表错误", "dev_id="..dev_id,
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

                -- tag 索引：每个点（group_offset==0）建一个 tag → reg 映射
                -- MQTT 协议按 tag 读写，需要这个索引从 tag 反查到 s_addr
                if i == 0 then
                    regs_by_tag[dev_id] = regs_by_tag[dev_id] or {}
                    regs_by_tag[dev_id][tpl.tag] = full_reg
                end
            end
        end
    end

    log.info("store", "初始化完成",
             "总slot数=" .. #expanded_regs,
             "cache_a_devs=" .. #cache_a,
             "cache_b_devs=" .. #cache_b)
    return true
end

-- 主站轮询成功后：按 A 的 (dev_id, s_addr) 更新 slot
function _M.write_by_a(dev_id, s_addr, data, err)
    local slot = cache_a[dev_id] and cache_a[dev_id][s_addr]
    if not slot then
        log.warn("store", "write_by_a",
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
-- MQTT 专用：按 tag 查 reg / 读缓存值
-- MQTT 协议用字符串 tag 标识点位，需要从 tag 反查到 reg 配置
-- ============================================================

-- 按 (dev_id, tag) 查完整 reg 配置（含 s_addr / reg_type / rw / reg_count）
function _M.get_reg_by_tag(dev_id, tag)
    if not regs_by_tag[dev_id] then return nil end
    return regs_by_tag[dev_id][tag]
end

-- 按 (dev_id, tag) 读缓存值
-- 返回: data, errcode
-- 多寄存器点位（reg_count>1）只返回首寄存器值，MQTT call 协议暂不支持多寄存器按 tag 读
function _M.read_by_tag(dev_id, tag)
    local reg = _M.get_reg_by_tag(dev_id, tag)
    if not reg then
        return nil, _M.ERR_UNINIT
    end
    return _M.read_by_b(dev_id, reg.n_addr)
end

return _M
