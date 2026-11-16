--[[
@module  topics
@summary MQTT 主题模板（唯一的 topic 字符串来源）
@version 1.0
@date    2026.11.13
@usage
与公司内部 MQTT 协议一致（协议文档 mqtt协议内容.md）。
所有上行/下行 topic 集中在这里定义，basic.lua 的 SUB_TABLE、
sender 发布时的 topic 都从这里拿，避免散落在多处。

topic 格式：/{动作}/{sn}
  sn = 模组 UID（mcu.unique_id():toHex()，8 字节 → 16 位 hex）
]]

local topics = {}

-- 模组唯一标识（UID 已验证 8 字节，16 字符 hex）
local SN = mcu.unique_id():toHex()
topics.SN = SN     -- 网关自身作为"虚拟设备"时的设备 id

-- ============================================================
-- 下行订阅（broker → 设备）
-- ============================================================
topics.SUB_DATA    = "/s/" .. SN     -- 主业务下行：call（查询）、set（写入）
topics.SUB_CONTROL = "/scr/" .. SN   -- 控制下行：indexReal、his、ctr
topics.SUB_CFG     = "/s2/" .. SN    -- 网关自身参数下行：call（读）、set（写）

-- 订阅表（basic.lua subscribe 时直接用）
topics.SUB_TABLE = {
    [topics.SUB_DATA]    = 0,
    [topics.SUB_CONTROL] = 0,
    [topics.SUB_CFG]     = 0,
}

-- ============================================================
-- 上行发布（设备 → broker）
-- ============================================================
topics.UP_DATA         = "/d/" .. SN    -- 实时数据：real / change / callack / setack / realIndex
topics.UP_RESUME       = "/dr/" .. SN   -- 断点续传（payload 同 real/change，只是 topic 不同）
topics.UP_HISTORY      = "/dh/" .. SN   -- 历史数据（payload 结构特殊：数组版）
topics.UP_CONTROL_ACK  = "/dcr/" .. SN  -- 控制应答：indexRealAck / hisAck / ctrAck
topics.UP_CFG          = "/d2/" .. SN   -- 网关自身参数：callack / setack / change

-- 以后扩展用（占位）
-- topics.UP_OTA    = "/do/" .. SN
-- topics.SUB_OTA   = "/so/" .. SN

return topics
