--[[
@module  ota
@summary 远程固件升级：HTTP 下载 → CRC32 校验 → fota 写入 → 重启
@version 1.0
@date    2026.11.16
@usage
由下行 /s2/${sn} 的 t="ota" 指令触发：

  {"t":"ota","d":{"03230619179356C9":{
      "url":"http://xxx/fw.bin","crc":"2339340852","size":"51200","mid":51}}}

规则：
  - body 必须且只能包含 url / crc / size 三个参数（允许 mid 额外存在）；
    任何缺漏、多余 → otaDownloadAck fail:["param"] + sys_last_error=ota_param；
  - URL 前后的反引号和空格会自动清理；
  - 升级进行中（下载/写 flash）重复下发 → otaDownloadAck fail:["busy"]；
  - 自动处理残留文件：size 正确且 CRC 通过 → 跳过下载；size 错 → 删了重下；
  - CRC 校验失败自动重下一次；
  - 下载完成后发 otaDownloadAck，校验完成后发 otaVerifyAck；
  - 两条 ack 都发完才开始 fota 写入，写入成功等待 2 秒再 reboot；
  - 升级期间 485 正常工作，不中断采集；
  - 但新的 OTA 指令和 sys_action（reboot/factoryReset）会被拦截。

应答：上行 /d2/${sn}，与 setack 同级。
  otaDownloadAck — 下载阶段结果
  otaVerifyAck   — CRC 校验阶段结果
  都用 ack.build("xxxAck", topics.SN, r, mid)

错误原因（r.fail + sys_last_error 同步记录）：
  param             参数缺失/多余/非法
  busy              升级中重复下发
  download          HTTP 下载失败（404/500/超时/文件大小不符）
  verify            CRC32 校验失败
  flash             fota 写入失败
  no_space          文件系统剩余空间不足
]]

local topics = require "topics"
local sender = require "sender"
local ack    = require "ack"
local cfg    = require "cfg"

local ota = {}

-- 固件存储路径：带项目名，避免和其他工程互相覆盖
local PROJECT_NAME  = (PROJECT and PROJECT ~= "") and PROJECT or "D700Tm_3RS485"
local FIRMWARE_PATH = "/" .. PROJECT_NAME .. "_upgrade.bin"

-- HTTP 下载超时（毫秒）
local HTTP_TIMEOUT_MS = 300000

-- 升级进行中（下载中 / 写 flash 中）
local busy = false

ota.FIRMWARE_PATH = FIRMWARE_PATH

-- ============================================================
-- 对外：升级中？供 down.lua 拦截 sys_action 和重复 OTA
-- ============================================================
function ota.is_busy()
    return busy
end

-- ============================================================
-- 内部辅助
-- ============================================================
local function set_error(code)
    cfg.set_last_error(code)
end

local function ack_download(mid, result)
    sender.publish(topics.UP_CFG, ack.build("otaDownloadAck", topics.SN, result, mid), 1)
    log.info("mqtt.ota", "otaDownloadAck 已发送", json.encode(result), "mid=" .. tostring(mid))
end

local function ack_verify(mid, result)
    sender.publish(topics.UP_CFG, ack.build("otaVerifyAck", topics.SN, result, mid), 1)
    log.info("mqtt.ota", "otaVerifyAck 已发送", json.encode(result), "mid=" .. tostring(mid))
end

-- ============================================================
-- 参数校验：必须且只能 {url, crc, size}（允许 mid 无关存在）
-- body 为空或非表 → fail param
-- 缺任一个 → fail param
-- 多任何非 url/crc/size/mid 的 key → fail param
-- 类型非法（url 不是 string、crc/size 不是正整数） → fail param
-- ============================================================
local function check_params(body)
    if type(body) ~= "table" then
        return nil, "ota_param"
    end

    -- 收集所有 key（跳过 mid）
    local keys = {}
    for k, _ in pairs(body) do
        if k ~= "mid" then keys[#keys + 1] = k end
    end
    table.sort(keys)

    -- 必须 { "crc", "size", "url" }
    local expected = { "crc", "size", "url" }
    if #keys ~= 3 then
        log.warn("mqtt.ota", "参数数量不对", #keys, "期望 3")
        return nil, "ota_param"
    end
    for i = 1, 3 do
        if keys[i] ~= expected[i] then
            log.warn("mqtt.ota", "参数内容不对", keys[i], "期望", expected[i])
            return nil, "ota_param"
        end
    end

    -- 类型校验
    local raw_url  = body.url
    local raw_crc  = body.crc
    local raw_size = body.size

    if type(raw_url) ~= "string" or raw_url == "" then
        return nil, "ota_param"
    end

    -- 去掉前后空格和误加的反引号
    local url = raw_url:match("^%s*`?(.-)`?%s*$") or raw_url

    -- CRC：支持十进制 / 0x 十六进制 / 纯十六进制
    -- 注意：32 位 Lua 上 0xFFFFFFFF 字面量会溢出成负数，不能用数值比较范围
    local crc
    if type(raw_crc) == "string" then
        local s = raw_crc:match("^%s*(.-)%s*$") or raw_crc

        -- 范围用字符串长度判断（避开 32 位整数溢出坑）
        local is_decimal = #s > 0 and #s <= 10 and s:match("^[0-9]+$") ~= nil
        local hex_body = s:match("^0[xX]([0-9a-fA-F]+)$")
        if not hex_body then hex_body = s:match("^([0-9a-fA-F]+)$") end

        if is_decimal then
            crc = tonumber(s)
        elseif hex_body and #hex_body <= 8 then
            crc = tonumber("0x" .. hex_body)
            if crc == nil then
                crc = 0
                for i = 1, #hex_body do
                    local c = hex_body:sub(i, i):lower()
                    local d = c:match("[0-9]") and tonumber(c) or
                              (c:match("[a-f]") and (c:byte() - 87))
                    if d == nil then crc = nil; break end
                    crc = crc * 16 + d
                end
            end
        end
    elseif type(raw_crc) == "number" then
        crc = raw_crc
    end
    if crc == nil then
        log.warn("mqtt.ota", "crc 格式非法", tostring(raw_crc))
        return nil, "ota_param"
    end

    -- size：必须是正整数
    local size = tonumber(raw_size)
    if size == nil or size <= 0 or size ~= math.floor(size) then
        return nil, "ota_param"
    end

    return { url = url, crc = crc & 0xFFFFFFFF, size = size }
end

-- ============================================================
-- CRC32 分块计算
-- ============================================================
local function crc32_file(path)
    local f = io.open(path, "rb")
    if not f then return nil end

    local crc = 0xFFFFFFFF
    local CHUNK = 512
    while true do
        local block = f:read(CHUNK)
        if not block then break end
        crc = crypto.crc32(block, crc, 0x04C11DB7, 0)
    end
    f:close()

    crc = crc ~ 0xFFFFFFFF
    return crc & 0xFFFFFFFF
end

-- ============================================================
-- 下载（或复用残留文件）
-- 返回：true 成功 / false + ack_fail_code + sys_error_code
-- ============================================================
local function download_or_reuse(url, crc, size)
    -- 空间检查：用 io.fsstat（demo 里的标准 API，返回 (ok, total_blk, used_blk, blk_size, fs_type)）
    local free
    if io and type(io.fsstat) == "function" then
        local ok, total, used, blk_size = io.fsstat("/")
        if ok and total and used and blk_size then
            free = (total - used) * blk_size
        end
    end
    if not free or free <= 0 then
        log.warn("mqtt.ota", "io.fsstat 不可用或返回异常，跳过空间检查")
        free = math.huge
    else
        log.info("mqtt.ota", "文件系统剩余空间", free, "字节")
    end

    -- 剩余空间 < 固件 size 的 10/9（即固件占了剩余空间的 90% 以上）就拒绝下载
    -- 保证写完固件后还至少剩 10% 的余量（给 ack 日志 + 重启缓冲）
    local needed = math.ceil(size / 0.9)
    if free < needed then
        log.error("mqtt.ota", "文件系统空间不足",
                  "剩余=" .. free, "固件=" .. size, "需要≥" .. needed)
        set_error("ota_no_space")
        return false, "no_space", "ota_no_space"
    end

    -- 看看有没有残留文件
    local existing = io.fileSize(FIRMWARE_PATH)

    if existing and existing == size then
        -- 大小正确，直接做 CRC（省一次下载）
        log.info("mqtt.ota", "发现完整固件，跳过下载", "size=" .. existing)
        return true
    end

    -- 大小不对或没有，先清掉再下载
    if existing and existing > 0 then
        log.warn("mqtt.ota", "残留固件大小不符，删除重下",
                 "残留=" .. existing, "期望=" .. size)
        os.remove(FIRMWARE_PATH)
    end

    log.info("mqtt.ota", "开始下载", url, "size=" .. size)

    local code = http.request("GET", url, nil, nil,
        { dst = FIRMWARE_PATH, timeout = HTTP_TIMEOUT_MS }).wait()

    if code ~= 200 then
        -- HTTP 非 200，清理残留
        os.remove(FIRMWARE_PATH)
        log.error("mqtt.ota", "HTTP 下载失败", code)

        if code == 404 then
            set_error("ota_http_404")
        elseif code >= 500 and code < 600 then
            set_error("ota_http_500")
        elseif code == -1 then
            set_error("ota_timeout")
        else
            set_error("ota_http_" .. tostring(code))
        end
        return false, "download", set_error_code or "ota_http_" .. tostring(code)
    end

    -- 200 OK，检查实际大小
    local actual = io.fileSize(FIRMWARE_PATH)
    if actual ~= size then
        log.error("mqtt.ota", "下载后文件大小不符",
                  "实际=" .. tostring(actual), "期望=" .. size)
        os.remove(FIRMWARE_PATH)
        set_error("ota_size_mismatch")
        return false, "download", "ota_size_mismatch"
    end

    log.info("mqtt.ota", "下载完成 size=" .. size)
    return true
end

-- ============================================================
-- 下载 + 自动重试（CRC 校验失败重下一次）
-- 返回：true 成功 / false + ack_fail_code + sys_error_code
-- ============================================================
local function download_with_retry(url, crc, size)
    local ok, fail_code, sys_code = download_or_reuse(url, crc, size)
    if not ok then return false, fail_code, sys_code end

    -- CRC 校验
    local actual_crc = crc32_file(FIRMWARE_PATH)
    if actual_crc == nil then
        log.error("mqtt.ota", "无法打开固件文件")
        set_error("ota_verify_io")
        return false, "verify", "ota_verify_io"
    end

    if actual_crc == crc then
        log.info("mqtt.ota", "CRC32 校验通过",
                 string.format("%08X", crc))
        return true
    end

    -- CRC 失败 → 自动重下一次
    log.warn("mqtt.ota", "CRC32 不匹配",
             "期望=" .. string.format("%08X", crc),
             "实际=" .. string.format("%08X", actual_crc),
             "删除重下")
    os.remove(FIRMWARE_PATH)

    ok, fail_code, sys_code = download_or_reuse(url, crc, size)
    if not ok then return false, fail_code, sys_code end

    actual_crc = crc32_file(FIRMWARE_PATH)
    if actual_crc == crc then
        log.info("mqtt.ota", "重下后 CRC32 校验通过")
        return true
    end

    log.error("mqtt.ota", "重下后 CRC32 仍不匹配",
              "期望=" .. string.format("%08X", crc),
              "实际=" .. string.format("%08X", actual_crc))
    os.remove(FIRMWARE_PATH)
    set_error("ota_crc_mismatch")
    return false, "verify", "ota_crc_mismatch"
end

-- ============================================================
-- fota 写入
-- 成功会 reboot，不返回
-- 失败返回 false
-- ============================================================
local function do_fota()
    log.warn("mqtt.ota", "=== 开始 fota 写入 ===")

    if not fota.init() then
        log.error("mqtt.ota", "fota.init() 失败")
        fota.finish(false)
        return false
    end

    while not fota.wait() do
        sys.wait(100)
    end

    fota.file(FIRMWARE_PATH)

    local ok, done = fota.isDone()
    if ok and done then
        fota.finish(true)
        log.warn("mqtt.ota", "固件写入成功，2 秒后重启")
        sys.wait(2000)
        rtos.reboot()
        return true
    end

    log.error("mqtt.ota", "fota 写入失败", "ok=" .. tostring(ok), "done=" .. tostring(done))
    fota.finish(false)
    set_error("ota_flash_write")
    return false
end

-- ============================================================
-- 对外主入口（down.lua 调用）
-- body = { url=..., crc=..., size=..., mid=... }
-- 内部起独立 task，避免阻塞 receiver
-- ============================================================
function ota.on_ota(body)
    local mid = body and body.mid

    if busy then
        log.warn("mqtt.ota", "升级进行中，忽略重复指令")
        set_error("ota_busy")
        ack_download(mid, { fail = { "busy" } })
        return
    end

    -- 参数校验
    local params, err = check_params(body)
    if not params then
        log.warn("mqtt.ota", "参数校验失败", err)
        set_error(err)
        ack_download(mid, { fail = { "param" } })
        return
    end

    busy = true
    sys.taskInit(function()
        local ok, err_msg = pcall(function()
            log.info("mqtt.ota", "OTA 开始",
                     "url=" .. params.url,
                     "size=" .. params.size,
                     "crc=0x" .. string.format("%08X", params.crc))

            -- 下载 + CRC 校验
            local ok2, fail_code, sys_code = download_with_retry(params.url, params.crc, params.size)

            if not ok2 then
                -- 下载失败（空间/HTTP/size mismatch）：直接 ack_download fail，不发 verify
                if fail_code == "download" or fail_code == "no_space" then
                    set_error(sys_code)
                    ack_download(mid, { fail = { fail_code } })
                else
                    -- verify 失败：下载阶段已过，先发 download success，再发 verify fail
                    ack_download(mid, { success = "all" })
                    set_error(sys_code)
                    ack_verify(mid, { fail = { fail_code } })
                end
                busy = false
                return
            end

            -- 下载 + CRC 都过：两条 ack success
            ack_download(mid, { success = "all" })
            ack_verify(mid, { success = "all" })

            -- 等 500ms 让 ack 发透
            sys.wait(500)

            -- fota 写入
            if do_fota() then
                -- 成功 → reboot 已执行，代码走不到这
            end

            -- fota 失败
            busy = false
            log.error("mqtt.ota", "升级失败，保留固件文件便于人工排查")
        end)

        if not ok then
            -- 任何意外异常（API 不存在、nil 调用等）：不重启设备，回 ack 后 busy 归零
            log.error("mqtt.ota", "OTA 任务异常：" .. tostring(err_msg))
            set_error("ota_internal")
            -- 只在还没发过 ack 时补发 download ack（verify 不发，因为走不到那）
            ack_download(mid, { fail = { "internal" } })
            busy = false
        end
    end)
end

return ota
