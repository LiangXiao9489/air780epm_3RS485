--[[
@module  down
@summary MQTT 下行 JSON 解析 + 按 topic/type 分发（唯一入口：dispatch）
@version 2.0
@date    2026.11.13
@usage
receiver.lua 在 "recv" 事件回调里拿到 topic 和 payload 后，
只需要调一行 down.dispatch(topic, payload)，down 内部会：
  1. 按 topic 找到对应的 handler 表
  2. json.decode payload 得到 msg
  3. 按 msg.t 找到对应的 type handler
  4. handler 回调里 sys.taskInit 独立 task 处理（不阻塞 receiver 回调）

两个下行 topic 各自的 type：
  /s/${sn}    → call（查询缓存）、set（写穿透热泵）
  /scr/${sn}  → indexReal、his、ctr（TODO）

已实现：
  call：按 tag 查 store 缓存 → up.with_time("callack", ...) → sender
  set ：按 tag 写穿透 u1 → 更新 store → ack.build("setack", ...) → sender

handler 回调签名：function(msg)  msg 是 decode 后的完整表

扩展方式：
  新增下行 topic → TOPIC_HANDLERS 加一行 { [topics.SUB_XXX] = { type=handler, ... } }
  新增 type     → 对应 handler 表里加一行 handlers.type = function(msg) ... end
]]

local topics          = require "topics"
local store           = require "store"
local core            = require "core"
local uart485         = require "hardware"
local downlink_lock   = require "downlink_uart_lock"
local up              = require "up"
local ack             = require "ack"
local sender          = require "sender"
local report          = require "report"

local down = {}

-- ============================================================
-- 工具函数
-- ============================================================

-- 获取当前时间字符串 "2018-10-10 16:01:47"
-- 未同步 NTP 时时间不准（1970 年起算），不影响功能，先跑起来
local function now_str()
    return os.date("%Y-%m-%d %H:%M:%S")
end

-- 检查 store 是否就绪（master 还没 init 完时为空）
local function store_ready()
    return store.get_all_regs() and #store.get_all_regs() > 0
end

-- JSON 对象的 key 永远是字符串（{"1":{...}}），而 point_table 里的 dev_id 是数字
-- 查 store 前必须归一化，否则 regs_by_tag["1"] 取不到 regs_by_tag[1]
-- 回包时仍用原始 key，保证和服务端下发的一致
local function norm_dev(dev_id)
    local n = tonumber(dev_id)
    return n or dev_id
end

-- 写穿透单个点位（线圈 0x05 / 保持寄存器 0x06）
-- reg:   store.get_reg_by_tag 返回的完整 reg
-- value: 数字
-- 返回: true/false
local function write_through_single(reg, value)
    local fc, adu
    if reg.reg_type == 1 then
        -- 线圈：0=OFF, 非0=ON（Modbus 0x05 写 ON 要发 0xFF00）
        local coil_val = (value ~= 0) and 0xFF00 or 0x0000
        fc = core.FC_WRITE_SINGLE_COIL
        adu = core.encode_request({
            dev_id = reg.dev_id,
            fc     = fc,
            addr   = reg.s_addr,
            value  = coil_val,
        })
    else
        -- 保持寄存器
        fc = core.FC_WRITE_SINGLE_REGISTER
        adu = core.encode_request({
            dev_id = reg.dev_id,
            fc     = fc,
            addr   = reg.s_addr,
            value  = value,
        })
    end

    if not adu then
        log.warn("mqtt.down", "写穿透 组帧失败", "dev=" .. reg.dev_id, "tag=" .. reg.tag)
        return false
    end

    if not downlink_lock.lock("mqtt_set") then
        log.warn("mqtt.down", "写穿透 获取 u1 锁超时", "tag=" .. reg.tag)
        return false
    end

    uart485.u1_send(adu)
    local resp_adu = uart485.u1_wait_response(2000)
    downlink_lock.unlock()

    if not resp_adu then
        log.warn("mqtt.down", "写穿透 超时", "dev=" .. reg.dev_id, "tag=" .. reg.tag)
        return false
    end

    local resp, err = core.decode_response(resp_adu, fc)
    if not resp then
        log.warn("mqtt.down", "写穿透 解帧失败", "tag=" .. reg.tag, "err=0x" .. string.format("%02X", err))
        return false
    end
    if resp.is_exception then
        log.warn("mqtt.down", "写穿透 从机异常", "tag=" .. reg.tag,
                 "ec=0x" .. string.format("%02X", resp.exception_code))
        return false
    end

    -- 成功：更新缓存
    store.write_by_a(reg.dev_id, reg.s_addr, value, 0)
    log.info("mqtt.down", "写穿透成功", "tag=" .. reg.tag, "value=" .. tostring(value))
    return true
end

-- ============================================================
-- handler 注册表：每个下行 topic 一张表，key = type, value = 回调
-- handler 回调里用 sys.taskInit 起独立 task，不阻塞 receiver
-- ============================================================
local TOPIC_HANDLERS = {
    -- /s/${sn}：主业务下行
    [topics.SUB_DATA] = {
        -- call 查询缓存：
        -- 下行: { t:"call", d:{ dev_id:{ ts:{tag1, tag2}, mid:1234 } } }
        -- 上行: { t:"callack", ti:"...", d:{ dev_id:{ tag1:{q,t,v}, tag2:{q,t,v} } } }
        call = function(msg)
            sys.taskInit(function()
                if not store_ready() then
                    log.warn("mqtt.down", "call store 未就绪")
                    return
                end
                local d = msg.d or {}
                for dev_id, body in pairs(d) do
                    local did = norm_dev(dev_id)
                    local mid = body.mid
                    local ts  = body.ts or {}
                    local result = {}

                    for _, tag in ipairs(ts) do
                        local slot = store.get_slot_by_tag(did, tag)
                        if not slot then
                            log.warn("mqtt.down", "call tag 不存在", dev_id, tag)
                            -- 协议：q 是质量位 0/1，拿不到点位按质量差处理
                            result[tag] = { q = "0", t = tostring(os.time()), v = "0" }
                        else
                            local ts = slot.ts
                            if not ts or ts == 0 then ts = os.time() end
                            result[tag] = {
                                q = (slot.errcode == 0) and "1" or "0",
                                t = tostring(ts),
                                v = tostring(slot.data or 0),
                            }
                        end
                    end

                    -- 协议：mid 放在设备对象里，和 tag 平级
                    if mid ~= nil then result.mid = mid end

                    local payload = up.with_time("callack", now_str(), { [dev_id] = result })
                    sender.publish(topics.UP_DATA, payload, 1)
                end
            end)
        end,

        -- set 写穿透：
        -- 下行: { t:"set", d:{ dev_id:{ tag1:val1, tag2:val2, mid:1234 } } }
        -- 上行: { t:"setack", d:{ dev_id:{ r:{success:"all"} 或 {fail:[...],not_found:[...]}, mid } } }
        set = function(msg)
            sys.taskInit(function()
                if not store_ready() then
                    log.warn("mqtt.down", "set store 未就绪")
                    return
                end
                local d = msg.d or {}
                for dev_id, body in pairs(d) do
                    local did = norm_dev(dev_id)
                    local mid = body.mid
                    local fail_tags = {}
                    local not_found_tags = {}
                    local all_ok = true

                    for tag, val in pairs(body) do
                        if tag ~= "mid" then
                            local reg = store.get_reg_by_tag(did, tag)
                            if not reg then
                                all_ok = false
                                not_found_tags[#not_found_tags + 1] = tag
                            elseif reg.rw ~= "rw" then
                                all_ok = false
                                fail_tags[#fail_tags + 1] = tag
                                log.warn("mqtt.down", "set 不可写", dev_id, tag,
                                         "reg_type=" .. reg.reg_type, "rw=" .. reg.rw)
                            elseif (reg.reg_count or 1) > 1 then
                                all_ok = false
                                fail_tags[#fail_tags + 1] = tag
                                log.warn("mqtt.down", "set 多寄存器点位不支持 tag 写入",
                                         dev_id, tag, "reg_count=" .. reg.reg_count)
                            else
                                local num_val = tonumber(val)
                                if num_val == nil then
                                    all_ok = false
                                    fail_tags[#fail_tags + 1] = tag
                                    log.warn("mqtt.down", "set 值非法", dev_id, tag, val)
                                else
                                    if not write_through_single(reg, num_val) then
                                        all_ok = false
                                        fail_tags[#fail_tags + 1] = tag
                                    end
                                end
                            end
                        end
                    end

                    local result
                    if all_ok then
                        result = { success = "all" }
                    else
                        -- 空数组不要带出去：Lua 空表 json.encode 成 {}，服务端按数组解析会出错
                        result = {}
                        if #fail_tags > 0 then result.fail = fail_tags end
                        if #not_found_tags > 0 then result.not_found = not_found_tags end
                    end
                    local payload = ack.build("setack", dev_id, result, mid)
                    sender.publish(topics.UP_DATA, payload, 1)
                end
            end)
        end,
    },

    -- /scr/${sn}：控制下行
    [topics.SUB_CONTROL] = {
        -- 首页实时数据快速上传：立即上报一次，之后按 iv 周期上报，du 秒后恢复
        indexReal = function(msg)
            log.info("mqtt.down", "indexReal 快速上传",
                     "sti=" .. tostring(msg.sti),
                     "du=" .. tostring(msg.du),
                     "iv=" .. tostring(msg.iv))
            report.start_index_real(msg)
        end,

        his = function(msg)
            log.info("mqtt.down", "his 历史召回", json.encode(msg.d))
        end,

        ctr = function(msg)
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
