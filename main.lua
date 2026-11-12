require "sys"

PROJECT = "Air780EPM_3RS485_Refactor"
VERSION = "666888"
pm.ioVol(pm.IOVOL_ALL_GPIO, 3300)

log.info("=========== 当前模组的固件版本是 [" .. VERSION .. "] =========")

-- 4G 蜂窝网络管理：SIM 通道 / SIM/IP 状态 / DNS / ICCID
require "net_4g"

-- 网络看门狗：5 分钟无网络活动自动重启（默认未启用，需要时取消注释）
-- require "net_watchdog"

sys.run()

