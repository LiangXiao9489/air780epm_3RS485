# Air780EPM 3 路 RS485 + MQTT 网关

> **硬件**：合宙 Air780EPM（EC718PM 内核，LuatOS Core）
> **运行时**：LuatOS（32 位协作式调度器）
> **定位**：多路 RS485 Modbus RTU 网关 + 4G MQTT 透传，支持多通道写穿透

---

## 一、项目做什么

把 Air780EPM 蜂窝模组改造成一台 **多路 Modbus 网关**：

- **u1（RS485_1）**：Modbus 主站，周期轮询下级 Modbus 从机，数据缓存到本地寄存器表
- **u2（RS485_2）**：Modbus 从站，响应上位机的读请求（查缓存）和写请求（**写穿透**到 u1 上的从机）
- **4G / MQTT**：按协议上行遥测数据（real / change / realIndex），下行接收 call / set / indexReal 指令
- **外部看门狗**：Air153C 硬件看门狗，GPIO28 喂狗，240s 超时兜底复位

### 关键特性

| # | 能力 | 说明 |
|---|---|---|
| 1 | 多从机支持 | 点表 `slave_dev={1,2,...}` 列出从机地址，共用一份寄存器模板 |
| 2 | 多寄存器类型 | 线圈(0x01) / 离散(0x02) / 保持(0x03) / 输入(0x04)，读写权限区分 |
| 3 | 写穿透 | u2 或 MQTT 收到写指令 → 抢占 u1 总线 → 向从机下发 → 回显 / 回 ack |
| 4 | 多通道串行化 | 所有对 u1 的事务共用一把互斥锁，主站轮询 / 从站写穿透 / MQTT 写穿透互不打架 |
| 5 | MQTT 完整生命周期 | create → auth → connect → subscribe → keepalive → 退避重连 |
| 6 | 队列式上行 | sender 串行发送，断线不丢，qos0/qos1 兼容，队列 64 条封顶 |
| 7 | 芯片 UID 身份 | MQTT ClientID / topic 后缀用 `mcu.unique_id():toHex()`，不依赖 SIM |
| 8 | 协议分层 | topic / 上行拼装 / ack 拼装 / 下行解析 / 上报调度各自一个文件 |
| 9 | 配置持久化 | `data/config.lua` 存 `/gateway_cfg.json`，OTA 新增字段自动 fallback 默认值 |
| 10 | 时间可信 | NITZ 基站校时 + `socket.sntp()`，时间未同步前拒绝上报假时间戳 |
| 11 | 网关参数远程配置 | `/s2` `/d2` 复用 set/call 结构，改 `config` 并落盘，`sys_need_reboot` 提示待重启 |

---

## 二、目录结构

```
D700Tm_3RS485/
├── main.lua                         入口：版本/UID 打印 + 配置快照 + 依次 require + sys.run()
│
├── data/                            跨模块共享数据
│   ├── store.lua                    寄存器缓存（主站写 / 从站读）+ tag 索引 + slot.ts
│   └── config.lua                   配置 JSON 持久化（/gateway_cfg.json）+ factory_reset
│
├── device/                          硬件相关
│   └── ext_wdt.lua                  Air153C 外部看门狗喂狗（GPIO28，120s 间隔）
│
├── modbus/                          Modbus 协议层（纯协议，不知道 MQTT）
│   ├── hardware.lua                 RS485 纯管道：2 路串口独立 send/wait_response
│   ├── core.lua                     Modbus RTU 编解码引擎（CRC16 / 组帧 / 解帧 / 异常码）
│   ├── downlink_uart_lock.lua       u1 总线互斥锁（lock / unlock / has_waiter，超时 800ms）
│   ├── point_table.lua              点表配置：从机地址 + 寄存器模板
│   ├── master.lua                   主站轮询 task（走 u1，每 block 先 lock）
│   └── slave.lua                    从站响应 task（走 u2，读查缓存，写穿透 u1）
│
├── wireless/                        与无线 / 云端相关的部分
│   ├── 4g/
│   │   ├── net_4g.lua               SIM 通道 / IMEI / DNS / IP_READY 监听
│   │   └── sntp.lua                 NTP 校时（IP_READY 后同步，成功 1 小时一次，失败 10s 重试）
│   │
│   ├── ota.lua                      远程固件升级：HTTP 下载 + CRC32 校验 + fota 写入 + 自动重下
│   │
│   └── mqtt/
│       ├── basic.lua                总调度：建链 / 订阅 / 事件分发 / 退避重连 / 部署参数打印
│       ├── sender.lua               上行发送队列：串行 / 断线保留 / PUBLISH_OK 推进
│       ├── receiver.lua             下行入队：task 内批量取空 → down.dispatch
│       └── protocol/                MQTT 协议层
│           ├── topics.lua           topic 常量表（/s、/scr、/s2、/d、/dh、/dr、/dcr、/d2）+ SUB_TABLE
│           ├── up.lua               上行 payload 拼装（with_time / without_time）
│           ├── ack.lua              应答 payload 拼装（setack / indexRealAck / hisAck）
│           ├── down.lua             下行解析 + 按 topic/type 分发（唯一入口 dispatch）
│           ├── cfg.lua              网关自身参数：注册表 + call/set + 参数变化 change
│           └── report.lua           上行调度：real / change / realIndex
│
├── _extra/                          OpenLuat 官方 demo 库（gitignore，仅作 API 参考）
│   ├── demo/fota/...                fota 核心库 / libfota2 扩展示例
│   ├── demo/http/...                http.request 下载到文件系统示例
│   ├── demo/crypto/...              crypto.crc32 / md5 示例
│   └── pre_version/src_user/        旧版本可运行代码（含 OTA / SNTP 参考实现）
│
└── README.md                        本文件
```

---

## 三、模块依赖关系

```
main.lua
 ├── config         → 无业务依赖（JSON 文件持久化）
 ├── ext_wdt        独立
 ├── net_4g         独立，设置 SIM / DNS，发布 IP_READY
 ├── sntp           独立，IP_READY 后 NTP 校时
 ├── master         → store + point_table + core + hardware + downlink_uart_lock
 ├── slave          → store + point_table + core + hardware + downlink_uart_lock
 └── basic          → sender + receiver + topics
                       receiver → down
                         down   → topics + store + core + hardware + downlink_uart_lock
                                  + up + ack + sender + report + cfg
                         report → topics + store + up + ack + sender + config
                         cfg    → config + up + sender + topics
                       sender  ←  basic（connect 时把 mqtt_client 交给它）
```

**关键设计**：硬件层（hardware）、Modbus 协议层（core）、数据层（store）、无线协议层（mqtt/protocol）、业务编排层（master / slave / basic）严格解耦。新增一个对上通道（例如 CAN 转 MQTT）时，**只需要加一个模块**，里面直接 `downlink_lock.lock()` + `uart485.u1_send()`，不碰 hardware / core / store 任何一行。

---

## 四、数据流

### 4.1 主站轮询（下行）

```
master task（每 5s 一轮）
  └── 按 (dev_id, reg_type, s_addr) 排序合并连续地址为 blocks
      └── 每个 block:
           downlink_lock.lock("master_poll")
             hardware.u1_send(adu)          [485 半双工，EN 自动翻转]
             hardware.u1_wait_response(800ms)
           downlink_lock.unlock()
           core.decode_response → store.write_by_a（更新缓存 slot.data / slot.errcode / slot.ts）
```

### 4.2 从站响应（上行 u2）

```
硬件从上位机收到 Modbus 帧 → hardware 接收回调 → resp_buffer → sys.publish
  └── slave task（u2_wait_response 等帧 → decode_request → 按 fc 分发）
      ├── 0x01/0x02/0x03/0x04 读 → store.read_by_b 查缓存 → encode_response
      └── 0x05/0x06/0x0F/0x10 写 → 组 u1 写穿透 ADU →
             downlink_lock.lock("slave_write_XX")
               hardware.u1_send(adu)
               hardware.u1_wait_response(2000ms)
             downlink_lock.unlock()
             decode_response → store.write_by_a（同步更新缓存）
             encode_response → u2_send 回显
```

### 4.3 MQTT 上下行

```
上行（业务模块 → broker）：
  report / down → sender.publish(topic, payload, qos) → send_queue →
  mqtt_client:publish → 等 PUBLISH_OK → 发下一条
  qos0 无 PUBACK，publish 返回即视为成功

下行（broker → 设备）：
  mqtt 事件回调 recv → receiver.proc（只入队，不解析）
  receiver task → sys.waitMsg → 批量取空 → down.dispatch(topic, payload)
    → 按 topic 选 handler 表 → 按 msg.t 选 handler → 业务处理 → sender.publish(ack)
```

### 4.4 u1 总线互斥（核心）

RS485 半双工**物理上不支持并发**。所有对 u1 的 Modbus 事务（主站轮询、从站写穿透、MQTT 写穿透）共用 `downlink_uart_lock.lua` 里的一把锁：

```lua
-- 主站轮询
downlink_lock.lock("master_poll")
uart485.u1_send(adu)
uart485.u1_wait_response(800)
downlink_lock.unlock()

-- 从站 / MQTT 写穿透（完全一样的模式）
downlink_lock.lock("mqtt_set")
uart485.u1_send(adu)
uart485.u1_wait_response(2000)
downlink_lock.unlock()
```

锁的范围 = **一个完整 Modbus 事务**（发请求 → 等响应 → 释放），中途绝不释放。等锁超时 800ms，多个等待者先到先得；主站每 block 前先 `has_waiter()` 让出，避免饿死写穿透。

---

## 五、点表配置（point_table.lua）

```lua
return {
    meta = {
        protocol_version = "xxxxxx_1.0.0",
        slave_dev = {1, 2},          -- 多台从机，共用下面这份 regs 模板
    },
    regs = {
        { num=1, tag="something1", reg_type=3, rw="rw",
          s_addr=5000, n_addr=6400, reg_count=1,
          data_type="u16", scale_factor=1 },
        { num=2, tag="multiHoldingReg", reg_type=3, rw="rw",
          s_addr=756, n_addr=252, reg_count=4,
          data_type="u64", scale_factor=1 },
        { num=3, tag="coilDemo", reg_type=1, rw="rw",
          s_addr=5100, n_addr=6500, reg_count=1 },
    },
}
```

启动时 `store.init(pt)` 自动展开成 `从机数 × regs` 份 slot，双向索引（cache_a 供主站轮询写、cache_b 供从站读），并建 `regs_by_tag[dev_id][tag]` 索引供 MQTT 的 call / set 使用。

| 字段 | 含义 |
|---|---|
| `reg_type` | 1=线圈 0x01 / 2=离散 0x02 / 3=保持 0x03 / 4=输入 0x04 |
| `rw` | `"r"`只读 / `"rw"`读写。reg_type=2/4 强制只读 |
| `s_addr` | 下行寄存器地址（主站轮询用） |
| `n_addr` | 上行寄存器地址（从站响应上位机用） |
| `reg_count` | 点位占用的寄存器个数，默认 1 |
| `scale_factor` | 原始值 × 系数 = 实际物理量（本地计算用） |
| `bits` | 可选，一个 16 位寄存器里装多个 bit 开关量（仅本地解析参考） |

---

## 六、MQTT 部署参数

地址、账密、ClientID 集中在 `wireless/mqtt/basic.lua` 顶部；topic 由 `wireless/mqtt/protocol/topics.lua` 统一生成。上电网络就绪后自动打印：

```
I/user.mqtt.main ======= 部署参数 =======
I/user.mqtt.main SERVER       = broker.emqx.io:1883
I/user.mqtt.main UID          = 03230619179356C9
I/user.mqtt.main CLIENT_ID    = YEDtest_D700Tm_mqtt_03230619179356C9
I/user.mqtt.main SUB_TOPICS   = {"/s/03230619179356C9":0,"/s2/03230619179356C9":0,"/scr/03230619179356C9":0}
I/user.mqtt.main USERNAME     = (空)
I/user.mqtt.main PASSWORD     = (空)
I/user.mqtt.main CLEAN_SESSION= true KEEPALIVE= 60s
I/user.mqtt.main ========================
```

| 参数 | 说明 |
|---|---|
| `UID` | `mcu.unique_id():toHex()`，8 字节硬件 UID（16 个 hex 字符），每颗模组不同 |
| `CLIENT_ID` | MQTT ClientID，broker 靠它区分设备；格式 `YEDtest_D700Tm_mqtt_<UID>` |
| `SUB_TOPICS` | 内容全部来自 `topics.SUB_TABLE`，当前为 `/s/${sn}` + `/scr/${sn}` + `/s2/${sn}` |
| `sn` | 协议里的网关号，等于 UID |
| `KEEPALIVE_SEC` | 心跳 60s，小于网络看门狗一半 |
| `RECONNECT_DELAY_MIN/MAX` | 重连退避 5s 起步，翻倍至 30s 封顶 |

---

## 七、MQTT 协议实现

### 7.1 topic

| 方向 | topic | 用途 | 状态 |
|---|---|---|---|
| 下行 | `/s/${sn}` | call / set | 已实现 |
| 下行 | `/scr/${sn}` | indexReal / ctr / his | indexReal 已实现；ctr、his 未实现 |
| 下行 | `/s2/${sn}` | 网关自身参数 call/set + OTA（`t=ota`） | 已实现（自定义扩展，见 7.6 / 7.7） |
| 上行 | `/d/${sn}` | real / change / realIndex / callack / setack | 已实现 |
| 上行 | `/d2/${sn}` | 网关自身参数 callack/setack/change + OTA ack | 已实现（自定义扩展，见 7.6 / 7.7） |
| 上行 | `/dcr/${sn}` | indexRealAck / ctrAck / hisAck | indexRealAck 已实现；其余未实现 |
| 上行 | `/dh/${sn}` | 历史数据（数组版 payload） | 未实现 |
| 上行 | `/dr/${sn}` | 断点续传（payload 与 `/d/` 相同） | 未实现 |

### 7.2 字段语义

| 字段 | 含义 |
|---|---|
| `t` | 报文类型：real / change / realIndex / callack / setack / indexRealAck |
| `ti` | 报文时间 `YYYY-MM-DD HH:MM:SS`；real 必须整 5 分钟 |
| `d` | 数据体，第一层 key 是设备 id（当前点表里就是从机地址，如 `"1"`） |
| `q` | 质量位 `"1"`/`"0"`，服务端只存 q=1 的点 |
| `t`（tag 内） | 采集时间，unix 秒字符串 |
| `v` | 值，字符串 |
| `mid` | 下行请求的 messageId，原样在 ack 里带回 |
| `r` | 应答结果：`{success:"all"}` 或 `{fail:[...], not_found:[...]}` |

> **失败占位值 `0xFFFF`（65535）**
>
> master 采集失败时（串口超时 / 解帧失败 / 从机回异常帧 / 响应缺值），缓存写入的不是 0，而是 `0xFFFF` 并带上错误码，`t` 同步更新为失败时刻（见 `modbus/master.lua`）。因此：
>
> - `v="65535"` **不代表真实值**：`0xFFFF` 与真实值 65535 在数值上无法区分，**只能靠 `q` 判断** —— `q="1"` 才是真实采集值，`q="0"` 表示本次采集失败、`v` 是占位值。
> - `change` 的判定同时比较 `v` 和 `q`，所以"值本来就是 0xFFFF、只是错误码变了"（`q` 1→0）同样会触发上报。
> - 持续失败不会反复刷屏：首条 change 后快照已是 `{v=65535, q=0}`，后续结果相同就不再报；恢复通信时 `q` 回到 1，会再上报一条。

### 7.3 上行

| 类型 | 触发 | 说明 |
|---|---|---|
| `real` | 每 `config.upload_interval_min` 分钟（默认 5）；另有 set 成功后补发的一次（见 7.5） | 全量点位，`ti` 与各点 `t` 都对齐整点（补发那条除外） |
| `change` | 每 `config.change_check_sec` 秒（默认 5）巡检 | 只报与快照不同的点，`ti` 用当前时间 |
| `realIndex` | 收到 indexReal 后立即一次 + 每 `iv` 一次，`du` 秒后停 | 只报指令里的目标点 |

### 7.4 下行

| 类型 | 行为 |
|---|---|
| `call` | 按 `d[dev].ts` 查 store 缓存 → `callack`（`q`/`t`/`v`/`mid`） |
| `set` | 多设备 × 每设备多属性，逐点写穿透 u1 → 更新缓存 → 每设备一条 `setack` → 只要有写入成功就补发一条 `real` |
| `indexReal` | 校验 `du`（-1/缺省或 >1800 不执行）→ 目标点位立即上报 + 按 `iv` 周期 → `indexRealAck` |

### 7.5 set 成功后补发 real（全量）

协议 2.4 末尾：

> iot 即使接到应答也不会修改自己的实时数据，需要控制器再发一条修改实时数据，格式与 2.1.1 相同。

实现约定（已定稿）：

| 项 | 约定 |
|---|---|
| 触发条件 | 一条 `set` 里**至少有一个点位写入成功**（`write_through_single` 返回 true） |
| 不触发的情况 | 全部失败：`not_found`（点位不存在）、`fail`（只读 / `reg_count>1` / 值非数字 / 从机超时或异常） |
| 上报范围 | **全量**：点表展开后的所有设备 × 所有点位，与整点 real 完全一致，不做点位过滤 |
| `topic` / `t` | `/d/${sn}`，`t = "real"` |
| `ti` | setack 发出后的当前时间，**不做整点对齐**（这条是"写入后立即补发"，不是整点 real） |
| tag 内 `t` | 各点位自己最新的采集时间（被写入的点就是写入时刻） |
| 顺序 | 先发该设备 `setack`，全部设备的 setack 发完后，再发这一条 real |
| 防重复 | 补发后立即 `commit_snapshot()`，同一次写入不会被下一轮 `change` 重复上报 |
| 落点 | `down.lua` 的 set handler → `report.send_real_after_set()` |

报文示例（省略号代表其余点位，实际是全量）：

```json
{
  "t": "real",
  "ti": "2026-11-15 14:35:33",
  "d": {
    "1": {
      "something1": { "q": "1", "t": "1794724533", "v": "123" },
      "coilDemo":   { "q": "1", "t": "1794724533", "v": "1" },
      "deviceSn":   { "q": "0", "t": "1794723722", "v": "65535" }
    }
  }
}
```

> 如果服务端以后改成"合并更新"语义，只需在 `send_real_after_set` 里把 `build_data(nil, nil)` 的第一个参数换成 `{ [dev_id] = { [tag] = true } }` 过滤表，其他逻辑不用动。

### 7.6 网关自身参数（`/s2` `/d2`，自定义扩展）

协议原文只有"采集点控制"（2.7），没有"网关自身参数读写"。这里按**不改协议结构、只换 topic** 的思路扩展：把网关自己当作一台虚拟设备，设备 id = 芯片 UID（`sn`），tag = 参数名，完全复用 `set` / `call` 的报文结构，服务端不需要新类型。

**改参数**

```json
// 下行 /s2/03230619179356C9 —— 一次改多个参数
{"t":"set","d":{"03230619179356C9":{"u1_baudrate":"19200","upload_interval_min":"10","mid":11}}}

// 上行 /d2/03230619179356C9 —— setack
{"t":"setack","d":{"03230619179356C9":{"mid":11,"r":{"success":"all"}}}}

// 上行 /d2/03230619179356C9 —— 参数变化 change（只含真正变了的 tag）
{"t":"change","ti":"2026-11-16 13:23:50","d":{"03230619179356C9":{
  "u1_baudrate":{"q":"1","t":"1794806630","v":"19200"},
  "sys_need_reboot":{"q":"1","t":"1794806630","v":"1"}}}}
```

**读参数 / 读状态**

```json
// 下行 /s2/03230619179356C9（ts 省略 = 读全部）
{"t":"call","d":{"03230619179356C9":{"ts":["u1_baudrate","sys_need_reboot"],"mid":58}}}
// 上行 /d2/03230619179356C9
{"t":"callack","ti":"2026-11-16 13:24:39","d":{"03230619179356C9":{
  "u1_baudrate":{"q":"1","t":"1794806630","v":"19200"},
  "sys_need_reboot":{"q":"1","t":"1794806679","v":"1"},
  "mid":58}}}
```

**行为约定**

| 项 | 约定 |
|---|---|
| 设备 id | 必须等于本机 `sn`（UID）；不匹配只打日志、不回包 |
| 值类型 | 下行字符串或裸数字都接受（`tonumber` 兜底）；上行一律字符串，bool 用 `"1"`/`"0"` |
| 多参数 | 与设备 set 一致：多个 tag 平铺、**逐项独立**，失败项进 `fail`/`not_found`，成功项照写 |
| 定时上报 | **无**：网关自身不做整点 real，也不参与 7.5 的 set 后 real 补发 |
| 变化上报 | 参数写入成功且值真的变了才发 `change`；`sys_need_reboot` 由 0 翻 1 时一并带上 |
| 持久化 | 写入即落盘 `/gateway_cfg.json`，断电重启后保持 |
| 生效时机 | 串口类参数需重启；上报周期类下一轮生效（见下表） |
| 参数 `t` | 最后一次写入时间；从未写过则取本次启动时间 |
| 失败判定 | 值非法/类型不符 → `fail`；只读项被写 → `fail`；未知 tag → `not_found` |
| 动作 | `sys_action`：`"reboot"` / `"factoryReset"`，见下方说明 |

**动作 `sys_action`**

不是配置项：不落盘、不可读、不出现在 `PARAM_ORDER` 里，只能通过 `set` 触发。

```json
// 下行 /s2/03230619179356C9
{"t":"set","d":{"03230619179356C9":{"sys_action":"reboot","mid":21}}}
// 上行 /d2/... —— 先回 setack，500ms 后再重启
{"t":"setack","d":{"03230619179356C9":{"mid":21,"r":{"success":"all"}}}}
```

| 取值 | 行为 |
|---|---|
| `reboot` | 回 setack 后 500ms 执行 `rtos.reboot()`，让落盘的串口参数生效 |
| `factoryReset` | 回 setack 后 500ms 删除 `/gateway_cfg.json` 并重启，配置回到代码默认值 |
| 其它值 | 进 `fail`，`sys_last_error = invalid_value`，不执行 |

> 500ms 延迟是为了让 sender 先把 `setack` 发出去，避免"设备已经重启、平台没收到应答"。
> 若此刻 MQTT 恰好断线，`setack` 会留在队列里随重启丢失——动作仍然执行。

**参数注册表**（`protocol/cfg.lua` → `REG`）

| key | 类型 | 范围 | 需重启 |
|---|---|---|---|
| `u1_baudrate` / `u2_baudrate` | number | 1200~115200 | 是 |
| `u1_databits` / `u2_databits` | number | 5~8 | 是 |
| `u1_stopbits` / `u2_stopbits` | number | 1~2 | 是 |
| `u1_parity` / `u2_parity` | string | N / E / O | 是 |
| `upload_interval_min` | number | 1~60 | 否 |
| `change_check_sec` | number | 1~60 | 否 |
| `write_through_en` | bool | `"1"`/`"0"` | 否 |

**只读状态**

| key | 说明 |
|---|---|
| `model` / `fw` / `sn` | 型号 / 固件版本 / UID |
| `imei` / `iccid` / `csq` / `ip` | 4G 信息 |
| `uptime_s` | 本次运行秒数 |
| `sys_need_reboot` | `"1"` = 有参数已保存、但需重启才生效 |
| `sys_last_error` | 最近一次 set 失败原因：`invalid_value` / `readonly` / `flash_fail` |

> **`requires_reboot` 与 `sys_need_reboot` 不要混用**
> `requires_reboot` 是注册表内部字段（`u1_baudrate = { requires_reboot = true }`），只决定"这类参数改完要不要重启"；`sys_need_reboot` 是唯一对外的只读 tag。读 `need_reboot` 会命中"未知参数"，返回 `{"q":"0","v":"0"}` 并打 warn。
>
> **`sys_last_error` 的语义**
> 只保留最近一次失败原因、不落盘、不主动上报，只能 call 读；未知 tag 的 `not_found` 不更新它。混合 set 中多个失败项时，最终记哪一条取决于 `pairs` 遍历顺序（不确定），但 `setack` 的 `fail` 数组已完整列出所有失败 tag。
>
> **重启策略**：写串口参数只落盘、**不自动重启**；由平台看到 `sys_need_reboot="1"` 后人工确认，再下发 `{"sys_action":"reboot"}`。这样避免串口参数写错导致重启后失联。

### 7.7 OTA 远程固件升级（`/s2` `/d2`，自定义扩展）

协议未定义 OTA 报文。复用 `/s2`（下行）和 `/d2`（上行），用 `t="ota"` 区分。

**下行**
```json
// 下行 /s2/${sn}
{"t":"ota","d":{"${sn}":{"url":"http://x/fw.bin","crc":"48D16E8F","size":"13766","mid":51}}}
```

必须且只能三个字段（`url` / `crc` / `size`），多一个少一个都回 `param` 错误。支持两种 CRC 写法：
- 十进制字符串：`"2339340852"`
- 十六进制：`"0x48D16E8F"` 或 `"48D16E8F"`

**上行**
```json
// 下载完成 /d2/${sn}
{"t":"otaDownloadAck","d":{"${sn}":{"r":{"success":"all"},"mid":51}}}

// 校验完成 /d2/${sn}
{"t":"otaVerifyAck","d":{"${sn}":{"r":{"success":"all"},"mid":51}}}
```

全部成功后：两阶段 ack → 等 500ms（让 ack 发出去）→ `fota` 写入 → 等 2000ms → 自动重启。重启后靠新 `fw` 版本号确认升级成功。

**失败路径**（`r.fail` 数组 + `sys_last_error`）

| `fail` | `sys_last_error` | 说明 |
|---|---|---|
| `param` | `ota_param` | url/crc/size 缺失、多余、或类型非法 |
| `no_space` | `ota_no_space` | 剩余空间 < 固件 size × 10/9（固件占了剩余 90% 以上） |
| `download` | `ota_http_404` / `ota_http_500` / `ota_timeout` | HTTP 下载失败 |
| `verify` | `ota_size_mismatch` / `ota_crc_mismatch` | 下载 size 与声明不符、CRC 校验失败（自动重下 1 次后仍失败） |
| `busy` | `ota_busy` | 升级过程中收到新的 `t=ota` 或 `sys_action` |
| - | `ota_flash_write` | `fota` 写入失败（不重启、固件文件保留、可重发指令） |

**锁与隔离**

- OTA 期间 `sys_action`（reboot / factoryReset）被拦截，回 `busy`，避免升级中断
- 升级期间新的 `t=ota` 被拦截，回 `busy`
- **不**暂停 Modbus 主从站（HTTP 下载与 485 轮询不抢资源）
- 整个流程用 `pcall` 兜底，任何未知错误 → 打日志 → 回 `internal` ack → `busy` 清零 → 设备不重启

**固件路径与分区**

- 下载到 `/Air780EPM_3RS485_Refactor_upgrade.bin`（`PROJECT` 变量，改工程名自动跟着改）
- 文件系统约 168KB，OTA 固件必须 ≤ 120KB（留剩余 ≥ 10%）
- 升级完成 / 失败都会清理残留文件

**实现落点**

- `wireless/ota.lua`：完整流程
- `protocol/down.lua`：`/s2` 路由 `t=ota` → `ota.handle()`
- `protocol/cfg.lua`：`sys_action` 在 `busy` 时被拦截

---

## 八、硬件接线

| 模块 | 引脚 | 说明 |
|---|---|---|
| RS485_1（u1） | UART1 + GPIO25（方向控制） | EN 软件翻转，9600 8N2 |
| RS485_2（u2） | UART2（硬件自动翻转） | 方向自动切换，9600 8N1 |
| 外部看门狗 | GPIO28（WTDOG） | 喂狗脉冲 > 200ms，间隔 ≤ 120s |
| SIM | SIM2（GPIO 模拟通道） | 贴片卡接通道 1 |

> u1 的方向控制脚 `GPIO25` 极性 `en_level=0`（低电平接收，高电平发送）。如果硬件实际相反，改 `hardware.lua` 里的 `u1_en_level`。

---

## 九、编译与烧录

### 9.1 固件镜像要求

- **硬件**：Air780EPM（EC718PM 内核）
- **内核版本**：V2016 及以上（支持 `mcu.unique_id()`、`crypto.crc32` 多参数、`io.dexist` 等新 API）
- **文件系统**：约 168 KB（内置 flash）

### 9.2 LuatTools 脚本搜索路径

必须包含以下目录（LuatOS 静态扫描打包）：

```
工程根目录/
├── main.lua                            ← 根目录本身
├── modbus/                             ← 6 个文件
├── data/                               ← 2 个文件（store / config）
├── device/                             ← 1 个文件（ext_wdt）
├── wireless/4g/                        ← 2 个文件（net_4g / sntp）
├── wireless/                           ← ota.lua 直接放 wireless/ 根目录
└── wireless/mqtt/                      ← 3 个文件（basic / sender / receiver）
    └── protocol/                       ← 5 个文件（topics / up / ack / down / report）
```

> `_extra/` 目录（OpenLuat 官方 demo）通过 `.gitignore` 排除，不参与打包，只作 API 参考。

### 9.3 打包注意

- `require` 名称必须是**字符串字面量**，LuatTools 扫不到变量拼接
- 所有 `require` 直接写模块名（如 `require "store"`），不带路径
- 核心库（`json`、`pack`、`crypto`、`socket`、`mqtt`、`fota`、`io`、`uart`、`mcu`、`mobile`）LuatOS 已内置，**不需要 require**
- 本地烧录调试时，删掉文件系统里的 `/gateway_cfg.json`，代码里的默认参数才会重新写入

---

## 十、功能实现状态

### 10.1 已实现

| # | 功能 | 落点 | 状态 |
|---|---|---|---|
| 1 | u1 主站轮询采集 | `modbus/master.lua` | 已联调 |
| 2 | u2 从站读写 + 写穿透 | `modbus/slave.lua` | 已联调 |
| 3 | u1 总线互斥 | `modbus/downlink_uart_lock.lua` | 已联调 |
| 4 | 寄存器缓存 + 采集时间 | `data/store.lua` | 已联调 |
| 5 | 配置持久化 + 出厂恢复 | `data/config.lua` | 已联调 |
| 6 | 4G 拨号 / DNS / SIM 状态 | `wireless/4g/net_4g.lua` | 已联调 |
| 7 | NTP 校时 | `wireless/4g/sntp.lua` | 已联调 |
| 8 | MQTT 建链 / 订阅 / 重连 / 参数打印 | `wireless/mqtt/basic.lua` | 已联调 |
| 9 | 上行 real（整 5 分钟全量） | `protocol/report.lua` | 已联调 |
| 10 | 上行 change（变化上报） | `protocol/report.lua` | 已联调 |
| 11 | 上行 realIndex（首页快速上传） | `report.start_index_real` | 已联调 |
| 12 | 下行 call（查缓存） | `protocol/down.lua` | 已联调 |
| 13 | 下行 set（多设备多属性写穿透） | `protocol/down.lua` | 已联调 |
| 14 | 网关自身参数读（`/s2` call → `/d2` callack） | `protocol/cfg.lua` | 已联调 |
| 15 | 网关自身参数写（`/s2` set → setack + 参数 change） | `protocol/cfg.lua` | 已联调 |
| 16 | 网关动作（`sys_action` = reboot / factoryReset） | `protocol/cfg.lua` | 已联调 |
| 17 | OTA 远程固件升级（参数校验 → 空间检查 → HTTP 下载 → CRC32 → fota 写入 → 重启） | `wireless/ota.lua` | 已联调 |
| 18 | set 成功后补发全量 real | `protocol/report.lua` | 已联调 |
| 19 | 外部看门狗 | `device/ext_wdt.lua` | 已启用 |

### 10.2 本次范围外（明确不做）

- `his` 历史召回 + `/dh` 上行
- `ctr` 采集点控制（2.7）
- 断点续传 `/dr`
- `alarm` 报警上报、设备 `on` / `off` 开关机（协议已标注整体废弃）
- 首页多用户计数的"停止快速上传"（协议已标注作废）
- `sys_token` / 鉴权（当前依赖 broker 侧 ACL，无内置校验）

---

## 十一、未实现 / 与协议冲突 / 语义不明

### 11.1 未实现

| 项 | 协议章节 | 说明 |
|---|---|---|
| `his` 历史召回 | 2.6 | 需要本地历史存储子系统 + `/dh` 数组版 payload（元素带 `ta`）；当前 `down.lua` 的 his handler 只打日志 |
| `ctr` 采集点控制 | 2.7 | 完全未实现：没有策略表，`down.lua` 的 ctr handler 只打日志；需要 `ot` 开关 / `iv` 间隔 / `du` 时长 + `ctrAck` |
| 断点续传 `/dr` | 2.1.1 注 | 断网期间 real 数据补传，需要历史缓存 + 发送进度持久化 |
| `sti` 预约生效 | 2.5 | indexReal 的 `sti`（开始时间）未实现，当前"收到即生效" |
| 多寄存器点位 set | 2.4 | `reg_count > 1` 的点不支持 `set`，直接进 `fail` |

### 11.2 与协议冲突（需修正）

| # | 问题 | 协议原文 | 当前实现 |
|---|---|---|---|
| 1 | setack 未带回当前值 | 2.4 上行示例里同时带 `tag1:{q,t,v}`（文档自己也标"暂时不确定"） | 只回 `r` + `mid` |
| 2 | `fail` 语义被扩大 | 2.4 中 `fail` 指"设置失败（如设备断电）" | 代码还把"点位不可写 `rw~="rw"` / 多寄存器 / 值非数字"都归入 `fail` |
| 3 | real 间隔可配 | 2.1.1 要求"必须整 5 分钟" | 按 `config.upload_interval_min` 对齐，改非 5 就违反协议 |
| 4 | callack 带 `ti` | 2.3 上行示例只有 `t` + `d`，**没有 `ti`** | 走 `up.with_time()` 自动附带 `ti`；`setack` 走 `ack.build()` 不带 `ti`，与协议一致 |

### 11.3 语义不明（需与服务端确认）

| # | 问题 | 现状 |
|---|---|---|
| 1 | `iv` 单位是毫秒还是秒 | 协议正文写毫秒，但示例都是 `"5"`；代码按秒（`IV_IS_SECOND = true`） |
| 2 | 设备 id 命名规则 | 协议示例是 `C1_D1`，点表 `dev_id` 是从机地址数字（`1`/`2`）；`down.lua` 用 `tonumber` 归一化，`"C1_D1"` 这类字符串会查不到点表 |
| 3 | tag 命名规则 | 协议示例是 `tag1`/`tag2`，实际点表是 `something1`/`机组状态`；若服务端固定发 `tagN`，需要加 `num ↔ tag` 映射 |
| 4 | `change` 的 `ti`/`t` 是否也要整点 | 协议只要求 real 整点；当前 change 用当前时间 |
| 5 | OTA 的 CRC 32 进制还是十进制 | 代码同时支持：十进制 `"2339340852"` / `0x` 前缀 `"0x48D16E8F"` / 纯十六进制 `"48D16E8F"`；建议平台固定一种（推荐十进制） |

### 11.4 工程风险（非协议问题）

| # | 风险 | 说明 |
|---|---|---|
| 1 | 时间未同步时静默不上报 | `os.time() < 1600000000` 时 real / change / realIndex 全部跳过，只每 30s 打一条告警；现场长期无网会被平台判"设备离线" |
| 2 | set 逐点写 | 一条 set 里 N 个点位 = N 次 Modbus 往返，且每个点位单独抢锁，可能被主站轮询插队 |
| 3 | sender 队列 64 条封顶 | 队列满时丢最旧一条（`MAX_QUEUE = 64`），长时间断网可能丢掉 Real 数据 |
| 4 | u1 锁超时 800ms | 多通道同时写穿透时可能偏紧，观察后考虑调大 |

---

## 十二、常用速查

| 操作 | 改哪里 |
|---|---|
| 换 broker / 改 ClientID 前缀 | `wireless/mqtt/basic.lua` 顶部部署参数 |
| 改上行周期 / 变化检测周期 / 写穿透开关 | `data/config.lua` → `DEFAULT_CFG` |
| 改网关参数注册表（类型/范围/是否需重启） | `wireless/mqtt/protocol/cfg.lua` → `REG` |
| 加网关只读状态项 | `wireless/mqtt/protocol/cfg.lua` → `status_get` + `READONLY` |
| 改可执行动作白名单 | `wireless/mqtt/protocol/cfg.lua` → `ACTIONS` + `on_set` 末尾 |
| 恢复出厂配置 | 删 `/gateway_cfg.json` 后重启，或调 `config.factory_reset()` |
| 加从机地址 | `modbus/point_table.lua` → `meta.slave_dev` |
| 加寄存器点位 | `modbus/point_table.lua` → `regs` 表 |
| 改 u1/u2 串口参数 / 方向控制脚 | `modbus/hardware.lua` → `u1_port` / `u2_port` 配置区 |
| 改 topic 模板 | `wireless/mqtt/protocol/topics.lua` |
| 改上报内容 / 策略 | `wireless/mqtt/protocol/report.lua` |
| 加新的下行 type | `wireless/mqtt/protocol/down.lua` → `TOPIC_HANDLERS` 对应表加一行 |
| 改喂狗引脚 / 间隔 | `device/ext_wdt.lua` 顶部 `EXT_WDT_PIN` / `EXT_WDT_FEED_INTERVAL_MS` |
| 换 SIM 通道 / DNS | `wireless/4g/net_4g.lua` |
| 调主站轮询间隔 | `modbus/master.lua` → `POLL_INTERVAL_MS` |

---

## 十三、官方支持渠道

| 资源 | 地址 |
|---|---|
| LuatOS 官方文档 | https://wiki.luatos.com |
| 合宙 IOT 平台 | https://iot.openluat.com |
| 官方 demo 仓库 | https://github.com/openLuat |
| 社区论坛 | https://www.luatos.com |
| 技术支持 | 合宙微信公众号 / 技术交流群 |
