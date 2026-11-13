# Air780EPM 3 路 RS485 + MQTT 网关

> **硬件**：合宙 Air780EPM（EC718PM 内核，LuatOS Core）
> **运行时**：LuatOS（32 位协作式调度器）
> **定位**：多路 RS485 Modbus RTU 网关 + 4G MQTT 透传，支持多通道写穿透

---

## 一、项目做什么

把 Air780EPM 蜂窝模组改造成一台 **多路 Modbus 网关**：

- **u1（RS485_1）**：Modbus 主站，周期轮询下级 Modbus 从机，数据缓存到本地寄存器表
- **u2（RS485_2）**：Modbus 从站，响应上位机的读请求（查缓存）和写请求（**写穿透**到 u1 上的从机）
- **4G / MQTT**：上行上报遥测数据，下行接收 JSON 指令（预留写穿透通道）
- **外部看门狗**：Air153C 硬件看门狗，GPIO28 喂狗，240s 超时兜底复位

### 关键特性

| # | 能力 | 说明 |
|---|---|---|
| 1 | 多从机支持 | 点表 `slave_dev={1,2,...}` 列出从机地址，共用一份寄存器模板 |
| 2 | 多寄存器类型 | 线圈(0x01) / 离散(0x02) / 保持(0x03) / 输入(0x04)，读写权限区分 |
| 3 | 写穿透 | u2 收到上位机写指令 → 抢占 u1 总线 → 向从机下发 → 回显 |
| 4 | 多通道串行化 | 所有对 u1 的事务共用一把互斥锁，主站轮询/从站写穿透/MQTT 写穿透互不打架 |
| 5 | MQTT 完整生命周期 | create → auth → connect → subscribe → keepalive → 退避重连 |
| 6 | 队列式上行 | sender 串行发送，断线不丢，qos0/qos1 兼容 |
| 7 | 芯片 UID 身份 | MQTT ClientID/Topic 用 `mcu.unique_id():toHex()`，不依赖 SIM |
| 8 | 部署参数集中打印 | 上电网络就绪后一次打出 broker/UID/topic 等，现场排查用 |

---

## 二、目录结构

```
D700Tm_3RS485/
├── main.lua                         入口文件：初始化 + 依次 require 各模块 + sys.run()
│
├── device/                          硬件相关
│   └── ext_wdt.lua                  Air153C 外部看门狗喂狗（GPIO28，120s 间隔）
│
├── modbus/                          Modbus 协议层（纯协议，不知道 MQTT）
│   ├── hardware.lua                 RS485 纯管道：2 路串口独立 send/wait_response
│   ├── core.lua                     Modbus RTU 编解码引擎（CRC16 / 组帧 / 解帧 / 异常码）
│   ├── shared.lua                   共享层：寄存器缓存 + u1 互斥锁（lock/unlock/has_waiter）
│   ├── point_table.lua              点表配置：从机地址 + 寄存器模板（s_addr / n_addr / reg_type / reg_count）
│   ├── master.lua                   主站轮询 task（走 u1，每 block 先 lock）
│   └── slave.lua                    从站响应 task（走 u2，读查缓存，写穿透 u1）
│
├── wireless/
│   ├── 4g/                          蜂窝网络
│   │   └── net_4g.lua               SIM 通道 / IMEI / DNS / IP_READY 监听
│   │
│   └── mqtt/                        MQTT 客户端（三层解耦）
│       ├── basic.lua                总调度：建链 / 订阅 / 事件分发 / 退避重连
│       ├── sender.lua               上行发送队列：串行 / 断线保留 / PUBLISH_OK 推进
│       └── receiver.lua             下行入队：task 内批量取空 + 分段日志
│
├── _extra/                          OpenLuat 官方 demo 库（gitignore，仅作 API 参考）
│   ├── demo/fota/...                fota 核心库 / libfota2 扩展示例
│   ├── demo/http/...                http.request 下载到文件系统示例
│   ├── demo/crypto/...              crypto.crc32 / md5 示例
│   └── ...
│
└── README.md                        本文件
```

---

## 三、模块依赖关系

```
main.lua
 ├── sys（LuatOS 内置）
 ├── ext_wdt        独立，不依赖任何业务模块
 ├── net_4g         独立，设置 SIM / DNS，发布 IP_READY
 ├── master         → shared + point_table + core + hardware
 ├── slave          → shared + point_table + core + hardware
 └── basic          → sender + receiver
                       sender  ←  basic（connect 时把 mqtt_client 交给它）
                       receiver ← basic（recv 事件回调里调用 proc 入队）
```

**关键设计**：硬件层（hardware）、协议层（core）、业务编排层（master/slave/basic）三层严格解耦。新增 MQTT 写穿透通道时，**只需要加一个模块**，里面直接 `shared.lock()` + `uart485.u1_send()`，不碰 hardware/core/shared 任何一行。

---

## 四、数据流

### 4.1 主站轮询（下行）

```
master task（每 5s 一轮）
  └── 按 (dev_id, reg_type, s_addr) 排序合并连续地址为 blocks
      └── 每个 block:
           shared.lock("master_poll")
             hardware.u1_send(adu)          [485 半双工，EN 自动翻转]
             hardware.u1_wait_response(800ms)
           shared.unlock()
           core.decode_response → shared.write_by_a（更新缓存 slot.data / slot.errcode）
```

### 4.2 从站响应（上行 u2）

```
硬件从上位机收到 Modbus 帧 → hardware 接收回调 → resp_buffer → sys.publish
  └── slave task（u2_wait_response 等帧 → decode_request → 按 fc 分发）
      ├── 0x01/0x02/0x03/0x04 读 → shared.read_by_b 查缓存 → encode_response
      └── 0x05/0x06/0x0F/0x10 写 → 组 u1 写穿透 ADU →
             shared.lock("slave_write_XX")
               hardware.u1_send(adu)
               hardware.u1_wait_response(2000ms)
             shared.unlock()
             decode_response → shared.write_by_a（同步更新缓存）
             encode_response → u2_send 回显
```

### 4.3 MQTT 上下行

```
上行（业务模块 → broker）：
  sender.publish(topic, payload, qos, cb) → send_queue →
  mqtt_client:publish → 等 PUBLISH_OK → 发下一条
  qos0 无 PUBACK，publish 返回即视为成功

下行（broker → 设备）：
  mqtt 事件回调 recv → receiver.proc（只入队，不解析）
  receiver task → sys.waitMsg → 批量取空 → 分段打印
  （协议确定后在此处按 msg.cmd 分发）
```

### 4.4 u1 总线互斥（核心）

RS485 半双工**物理上不支持并发**。所有对 u1 的 Modbus 事务（主站轮询、从站写穿透、未来 MQTT 写穿透）共用 `shared.lua` 里的一把锁：

```lua
-- 主站轮询
shared.lock("master_poll")
uart485.u1_send(adu)
uart485.u1_wait_response(800)
shared.unlock()

-- 从站写穿透（完全一样的模式）
shared.lock("slave_write_06")
uart485.u1_send(adu)
uart485.u1_wait_response(2000)
shared.unlock()
```

锁的范围 = **一个完整 Modbus 事务**（发请求 → 等响应 → 释放）。超时 800ms，多个等待者 FIFO 唤醒。主站每 block 前先 `shared.has_waiter()` 让出，避免饿死写穿透。

---

## 五、点表配置（point_table.lua）

```lua
return {
    meta = {
        protocol_version = "xxxxxx_1.0.0",
        slave_dev = {1, 2},          -- 多台从机，共用下面这份 regs 模板
    },
    regs = {
        -- 示例 1：单寄存器 holding，从机 s_addr=100，上位机 n_addr=1000
        {
            num=1, tag="冷却温度", reg_type=3, rw="rw",
            s_addr=100, n_addr=1000, reg_count=1,
            data_type="u16", scale_factor=0.1,
        },
        -- 示例 2：多寄存器 holding，占用 2 个寄存器 (u32)
        {
            num=2, tag="累计电量", reg_type=3, rw="rw",
            s_addr=200, n_addr=2000, reg_count=2,
            data_type="u32", scale_factor=1,
        },
        -- 示例 3：coil（线圈），单 bit
        {
            num=3, tag="启动/停止", reg_type=1, rw="rw",
            s_addr=0, n_addr=3000, reg_count=1,
        },
    },
}
```

启动时 `shared.init(pt)` 会自动展开成 `从机数 × regs` 份 slot，双向索引（cache_a 供主站轮询写、cache_b 供从站读）。

| 字段 | 含义 |
|---|---|
| `reg_type` | 1=线圈 0x01 / 2=离散 0x02 / 3=保持 0x03 / 4=输入 0x04 |
| `rw` | `"r"`只读 / `"rw"`读写。reg_type=2/4 强制只读 |
| `s_addr` | 下行寄存器地址（主站轮询用） |
| `n_addr` | 上行寄存器地址（从站响应上位机用） |
| `reg_count` | 点位占用的寄存器个数，默认 1 |
| `scale_factor` | 原始值 × 系数 = 实际物理量（本地计算用） |
| `bits` | 可选，一个 16 位寄存器里装多个 bit 开关量 |

---

## 六、MQTT 部署参数

所有参数集中在 `wireless/mqtt/basic.lua` 文件顶部，启动时会自动打印：

```
I/user.mqtt.main ======= 部署参数 =======
I/user.mqtt.main SERVER       = broker.emqx.io:1883
I/user.mqtt.main UID          = 03230619179356C9
I/user.mqtt.main CLIENT_ID    = YEDtest_D700Tm_mqtt_03230619179356C9
I/user.mqtt.main TOPIC_UP     = YEDtest/D700Tm/Pub/03230619179356C9
I/user.mqtt.main TOPIC_DOWN   = YEDtest/D700Tm/Sub/03230619179356C9
I/user.mqtt.main USERNAME     = (空)
I/user.mqtt.main PASSWORD     = (空)
I/user.mqtt.main CLEAN_SESSION= true KEEPALIVE= 60s
I/user.mqtt.main ========================
```

| 参数 | 说明 |
|---|---|
| `UID` | `mcu.unique_id():toHex()`，8 字节硬件 UID，每颗模组不同 |
| `CLIENT_ID` | MQTT 协议 ClientID，broker 靠它区分设备；格式 `YEDtest_D700Tm_mqtt_<UID>` |
| `TOPIC_UP` | 上行发布主题：`YEDtest/D700Tm/Pub/<UID>` |
| `TOPIC_DOWN` | 下行订阅主题：`YEDtest/D700Tm/Sub/<UID>` |
| `KEEPALIVE_SEC` | 心跳 60s，小于网络看门狗一半 |
| `RECONNECT_DELAY_MIN/MAX` | 重连退避 5s 起步，翻倍至 30s 封顶 |

> ⚠️ 改 topic 前缀或 CLIENT_ID 格式后，**broker 端的订阅也要同步改**。UID 版本下，每台设备 topic 唯一，不存在互相踢掉的风险（之前 IMEI 兜底 `"DEV0001"` 会撞车）。

---

## 七、硬件接线

| 模块 | 引脚 | 说明 |
|---|---|---|
| RS485_1（u1） | UART1 + GPIO25（方向控制） | EN 软件翻转，9600 8N2 |
| RS485_2（u2） | UART2（硬件自动翻转） | 方向自动切换，9600 8N1 |
| 外部看门狗 | GPIO28（WTDOG） | 喂狗脉冲 > 200ms，间隔 ≤ 120s |
| SIM | SIM2（GPIO 模拟通道） | 贴片卡接通道 1 |

> u1 的方向控制脚 `GPIO25` 极性 `en_level=0`（低电平接收，高电平发送）。如果硬件实际相反，改 `hardware.lua` 里的 `u1_en_level`。

---

## 八、编译与烧录

### 8.1 固件镜像要求

- **硬件**：Air780EPM（EC718PM 内核）
- **内核版本**：V2016 及以上（支持 `mcu.unique_id()`、`crypto.crc32` 多参数、`io.dexist` 等新 API）
- **文件系统**：约 168 KB（内置 flash）

### 8.2 LuatTools 脚本搜索路径

必须包含以下目录（LuatOS 静态扫描打包）：

```
工程根目录/
├── main.lua                            ← 根目录本身
├── modbus/                             ← 6 个文件
├── wireless/mqtt/                      ← 3 个文件（basic/sender/receiver）
├── wireless/4g/                        ← 2 个文件（net_4g/net_watchdog）
└── device/                             ← 1 个文件（ext_wdt）
```

> `_extra/` 目录（OpenLuat 官方 demo）通过 `.gitignore` 排除，不参与打包，只作 API 参考。

### 8.3 打包注意

- `require` 名称必须是**字符串字面量**，LuatTools 扫不到变量拼接
- 核心库（`json`、`pack`、`crypto`、`socket`、`mqtt`、`fota`、`io`、`uart`、`mcu`、`mobile`）LuatOS 已内置，**不需要 require**
- `crypto.crc32(data, start, poly, xorout)` 是 2025.4.14 新增的多参数形式，必须用 V2016+ 固件

---

## 九、扩展指南

### 9.1 新增 4G 写穿透通道

```
broker → MQTT receiver.task（解析 JSON 里的写指令）
  → sys.taskInit 独立 task（避免阻塞 receiver）
    → 点表校验（dev_id + n_addr → reg_type == 3 且 rw == "rw"）
    → core.encode_request 组 ADU（s_addr）
    → shared.lock("mqtt_write")
        uart485.u1_send(adu)
        hardware.u1_wait_response(2000)
      shared.unlock()
    → decode_response → shared.write_by_a
    → sender.publish(ack)
```

### 9.2 新增寄存器点位

编辑 `modbus/point_table.lua` 里的 `regs` 表，加一行模板。**启动时 `shared.init` 会自动展开**——主站轮询、从站响应、缓存 slot 全链路自动打通，不需要改其他模块。

### 9.3 新增多从机

把 `meta.slave_dev = {1}` 改成 `{1, 2, 3}`，其他同上。

### 9.4 替换 broker 地址

编辑 `wireless/mqtt/basic.lua` 顶部 `SERVER_ADDR / SERVER_PORT / USERNAME / PASSWORD` 四个变量即可。

---

## 十、已知限制 & 演进方向

| 方向 | 现状 | 建议 |
|---|---|---|
| 主站轮询块合并 | 按 (dev_id, reg_type) 合并连续 s_addr | FC03/04 最多 125 个寄存器，FC01/02 最多 2000 个 bit，当前实现已处理 |
| u1 锁超时 | 800ms（`shared.LOCK_TIMEOUT_MS`） | 多通道同时写穿透时可能不够，观察后调至 2000-3000ms |
| OTA 流水线 | `_extra/pre_version/src_user/user_ota.lua` 保留代码，未接入 | 建议用 `libfota2`（仓库有 demo），HTTP 下载 + CRC32 + fota 核心库 |
| 网络看门狗 | `net_watchdog.lua` 已实现但 main.lua 注释掉 | 联调稳定后启用 |
| 下行协议分发 | receiver.lua 当前只打印，不解析 | 按 `cmd == "ota"` / `cmd == "write"` 分支扩展 |
| 固件版本标识 | main.lua 里 `VERSION = "666888"` 硬编码 | 接入 OTA 后从 `rtos.version()` 或上报里自动带出 |

---

## 十一、常用速查

| 操作 | 改哪里 |
|---|---|
| 换 broker / 改 topic / 改 ClientID 前缀 | `wireless/mqtt/basic.lua` 顶部部署参数 |
| 加从机地址 | `modbus/point_table.lua` → `meta.slave_dev` |
| 加寄存器点位 | `modbus/point_table.lua` → `regs` 表 |
| 改 u1/u2 串口参数 / 方向控制脚 | `modbus/hardware.lua` → `u1_port` / `u2_port` 配置区 |
| 改喂狗引脚 / 间隔 | `device/ext_wdt.lua` 顶部 `EXT_WDT_PIN` / `EXT_WDT_FEED_INTERVAL_MS` |
| 启用/停用网络看门狗 | `main.lua` 注释切换 |
| 换 SIM 通道 / DNS | `wireless/4g/net_4g.lua` |
| 调主站轮询间隔 | `modbus/master.lua` → `POLL_INTERVAL_MS` |

---

## 十二、官方支持渠道

| 资源 | 地址 |
|---|---|
| LuatOS 官方文档 | https://wiki.luatos.com |
| 合宙 IOT 平台 | https://iot.openluat.com |
| 官方 demo 仓库 | https://github.com/openLuat |
| 社区论坛 | https://www.luatos.com |
| 技术支持 | 合宙微信公众号 / 技术交流群 |
