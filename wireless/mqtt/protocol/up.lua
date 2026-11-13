--[[
@module  up
@summary MQTT 上行数据类 JSON 拼装（纯字符串进出，不碰 topic、不碰 sender）
@version 1.0
@date    2026.11.13
@usage
只负责"顶层 JSON key 拼装 + json.encode"，dev_data 的结构由调用方决定。
这样不管 dev 里是 tag 字典、tag 字典+mid 都能处理。

两种顶层结构：
  带时间：{ t, ti, d }     — real / change / realIndex / callack / his
  无时间：{ t, d }         — 保留给未来扩展（当前 ack 类走 ack.lua）

NOTICE：ack 类（setack/indexRealAck/hisAck/ctrAck）结构特殊（dev 里有 r 和 mid），
        走 ack.lua；本文件只管数据上报类。

调用示例：
  -- real 上报
  local payload = up.with_time("real", time_str, dev_data_dict)
  sender.publish(topics.UP_DATA, payload, 1)

  -- his 历史上报（dev_data 是数组版）
  local payload = up.with_time("his", time_str, dev_data_array)
  sender.publish(topics.UP_HISTORY, payload, 1)
]]

local up = {}

-- 带时间戳的标准结构
-- type_str: "real" / "change" / "realIndex" / "callack" / "his"
-- ti:       "2018-10-10 16:01:47" 格式时间字符串
-- dev_data: { dev_id = ... }   调用方决定内部结构（tag 字典 / tag 字典+mid / 数组版）
function up.with_time(type_str, ti, dev_data)
    return json.encode({ t = type_str, ti = ti, d = dev_data })
end

-- 不带时间戳（保留给未来扩展）
function up.without_time(type_str, dev_data)
    return json.encode({ t = type_str, d = dev_data })
end

return up
