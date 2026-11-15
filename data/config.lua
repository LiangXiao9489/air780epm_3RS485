--[[
@module  config
@summary 网关运行时配置（JSON 文件持久化，按需 fallback 默认值）
@version 1.0
@date    2026.11.13
@usage
所有"运行时可配置"的参数都在这里集中管理，文件系统落盘，重启不丢失。

文件位置：/gateway_cfg.json（内置 flash 根目录，Air780EPM 约 168KB 够放几百份）
首次启动：文件不存在 → 写入 DEFAULT_CFG 到文件
后续启动：文件存在 → 读入内存；OTA 新增字段时 get() 自动 fallback 默认值

对外 API：
  init()                require 即自动调用，读文件或写默认
  get(key)              读参数，文件缺这个 key 时 fallback DEFAULT_CFG[key]
  set(key, val)         改内存 + 写文件
  all()                 返回当前内存中的完整 cfg table（只读，别改）

main.lua require 顺序要求：
  require "config"   ← 必须最先，hardware.lua init 串口时要读它
  require "hardware"
  ...

NOTICE：DEFAULT_CFG 里的 key 是"运行时可配"的全量集合。
硬件焊死的参数（GPIO 端口号、EN 控制脚）不要放这里，继续写死在 hardware.lua。
]]

local _M = {}

-- ============================================================
-- 文件路径 + 默认参数集合（OTA 新增字段时往这里加，get() 自动兜底）
-- ============================================================
local CONFIG_PATH = "/gateway_cfg.json"

-- 默认参数（按功能分组）
local DEFAULT_CFG = {
    -- ---------- 串口参数（可运行时改，改完重启串口生效） ----------
    u1_baudrate  = 9600,      -- u1：下行 Modbus 主站
    u1_databits  = 8,
    u1_stopbits  = 2,
    u1_parity    = "N",       -- "N" / "E" / "O"
    u2_baudrate  = 9600,      -- u2：上行 Modbus 从站
    u2_databits  = 8,
    u2_stopbits  = 1,
    u2_parity    = "N",

    -- ---------- 业务参数 ----------
    upload_interval_min = 5,   -- MQTT 实时数据上报间隔（分钟，需为整分钟对齐）
    change_check_sec    = 5,   -- 变化数据检测周期（秒）
    write_through_en    = true,-- 是否允许 u2/MQTT 写穿透到热泵

    -- ---------- MQTT 传输层参数（basic.lua 里写死的可以逐步迁过来） ----------
    -- mqtt_port = 1883,      -- 保留占位，basic.lua 还没接这个
}

-- 内存镜像（init() 填充）
local cfg

-- ============================================================
-- 内部：先定义 save，因为 load_or_init 要调它
-- ============================================================
local function save()
    -- 只把当前 cfg 里有定义的 key 写入文件
    -- （set() 时才会有，read-only fallback 不会污染文件）
    local f = io.open(CONFIG_PATH, "w")
    if f then
        f:write(json.encode(cfg))
        f:close()
    else
        log.error("config", "写入失败，磁盘可能满了")
    end
end

-- ============================================================
-- 内部：从文件读或写默认
-- ============================================================
local function load_or_init()
    local f = io.open(CONFIG_PATH, "r")
    if f then
        local raw = f:read("*a")
        f:close()
        cfg = json.decode(raw)
        if type(cfg) ~= "table" then
            log.warn("config", "文件损坏，用默认值覆盖")
            cfg = {}
            save()
        end
    else
        log.info("config", "首次启动，写入默认配置")
        cfg = {}
        -- 把默认值全量写入 cfg，这样文件里有完整快照
        for k, v in pairs(DEFAULT_CFG) do cfg[k] = v end
        save()
    end
end

-- ============================================================
-- 对外 API
-- ============================================================

-- 读参数：文件里有就用文件的，没有就 fallback 默认值
function _M.get(key)
    local v = cfg[key]
    if v == nil then
        return DEFAULT_CFG[key]   -- 文件里没有这个 key（包括 OTA 新增字段的场景）
    end
    return v
end

-- 写参数：改内存 + 立刻落盘
function _M.set(key, val)
    cfg[key] = val
    save()
end

-- 返回完整内存表（调用方只读，别改里面的值，改了不走 save）
function _M.all()
    return cfg
end

-- 读完整默认表（调试用）
function _M.defaults()
    return DEFAULT_CFG
end

-- 恢复出厂：清空内存配置 → 删除文件 → 重启
-- 下次启动 load_or_init 会检测到文件不存在，自动全量写入 DEFAULT_CFG
-- 调用方（比如 MQTT 层的 factoryReset type）不用关心内部细节
function _M.factory_reset()
    log.warn("config", "恢复出厂设置！")
    cfg = {}
    os.remove(CONFIG_PATH)
    log.info("config", "配置文件已删除，即将重启...")
    rtos.reboot()
end

-- ============================================================
-- 模块加载时自动 init（require "config" 即运行）
-- ============================================================
load_or_init()
log.info("config", "初始化完成", "文件=" .. CONFIG_PATH)

return _M
