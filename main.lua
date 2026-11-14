require "sys"

PROJECT = "Air780EPM_3RS485_Refactor"
VERSION = "666888"
pm.ioVol(pm.IOVOL_ALL_GPIO, 3300)

log.info("=========== 当前模组的固件版本是 [" .. VERSION .. "] =========")
log.info("=========== 芯片 UID [" .. mcu.unique_id():toHex() .. "] =========")


-- ============================================================
-- 运行时配置（JSON 文件持久化）：必须最先加载，hardware.lua init 串口时要读
-- ============================================================
local config = require "config"
log.info("config", "运行时参数快照", json.encode(config.all()))

-- 外部硬件看门狗（Air153C，WTDOG=GPIO28）：require 即启动喂狗 task
require "ext_wdt"

-- 4G 蜂窝网络管理：SIM 通道 / SIM/IP 状态 / DNS / ICCID
require "net_4g"

-- 网络看门狗：5 分钟无网络活动自动重启（默认未启用，需要时取消注释）
-- require "net_watchdog"

-- Modbus 网关：主站轮询 u1（下行采集）+ 从站响应 u2（上行透传/写穿透）
-- require "master"
-- require "slave"

-- MQTT 客户端：建链 / 订阅 / 上下行收发（wireless/mqtt/）
require "basic"

sys.run()

