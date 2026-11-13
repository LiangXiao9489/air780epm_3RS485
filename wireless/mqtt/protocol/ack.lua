--[[
@module  ack
@summary MQTT 上行 ack 应答构造（setack / indexRealAck / hisAck / ctrAck 共用）
@version 1.0
@date    2026.11.13
@usage
四种 ack 类型 payload 结构完全一致，只有顶层 t 字符串不同。

payload 格式：
{
  "t(type)": "setack" | "indexRealAck" | "hisAck" | "ctrAck",
  "d(data)": {
    "dev_id": {
      "r(result)": { "success":"all" }  |  { "fail":["tag1"], "not_found":["tag3"] },
      "mid(messageId)": 1234
    }
  }
}

调用示例：
  -- set 指令应答（写入成功）
  local payload = ack.build("setack", "C1_D1", {success="all"}, 1234)
  sender.publish(topics.UP_DATA, payload, 1)

  -- ctr 指令应答（部分失败）
  local payload = ack.build("ctrAck", "C1_D1", {fail={"tag1"}, not_found={"tag2"}}, 5678)
  sender.publish(topics.UP_CONTROL_ACK, payload, 1)
]]

local ack = {}

-- 构造单设备 ack
-- type_str:  "setack" / "indexRealAck" / "hisAck" / "ctrAck"
-- dev_id:    设备字符串（如 "C1_D1"）
-- result:    { success="all" }  或  { fail={...}, not_found={...} }
-- mid:       下行指令里带的 messageId，原样带回（可选，nil 则不写）
function ack.build(type_str, dev_id, result, mid)
    local dev_item = { r = result }
    if mid ~= nil then
        dev_item.mid = mid
    end
    return json.encode({
        t = type_str,
        d = { [dev_id] = dev_item }
    })
end

-- 批量构造多设备 ack（协议说"多个设备不必须在一条里"，支持但不强制）
-- dev_items: { {dev="C1_D1", r={success="all"}, mid=1234}, {dev="C1_D2", ...} }
function ack.build_batch(type_str, dev_items)
    local d = {}
    for _, item in ipairs(dev_items) do
        local dev_item = { r = item.r }
        if item.mid ~= nil then
            dev_item.mid = item.mid
        end
        d[item.dev] = dev_item
    end
    return json.encode({ t = type_str, d = d })
end

return ack
