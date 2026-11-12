--[[
@module  point_table
@summary Modbus 点表配置（下行 A / 上行 B 的寄存器映射）
@version 1.0
@date    2026.11.06
@usage
1. 多台从机共用同一份 regs 模板，只需在 meta.slave_dev 里列出从机地址
2. 启动时 modbus_store 会自动把 regs 展开成 (dev_id × regs) 份，每份带 dev_id
3. s_addr  = 下行寄存器地址（点表 A，主站轮询用）
   n_addr  = 上行寄存器地址（点表 B，从站响应上位机用）
   reg_type = 1:coil(0x01) 2:discrete(0x02) 3:holding(0x03) 4:input(0x04)
              （reg_type 数字 = Modbus 功能码数字，业界惯例）
   rw      = "r"只读 / "rw"读写（reg_type=2/4 强制只读，写请求返回0x01非法功能码）

   reg_count = 该点占用的寄存器个数，默认 1
               长度的唯一权威来源，与数据类型无关：
               - 单寄存器：reg_count=1
               - u32/i32/f32：通常 reg_count=2
               - SN/型号/版本号等字节串：reg_count=寄存器数（16字节 SN = 8）
               说明：
               - 启动时按 reg_count 展开成多个 16 位 slot，主站自动合并轮询，
                 上位机从 n_addr 起整组读取即可，无需额外处理
               - 多寄存器点位若 rw="rw"，上位机必须用 0x10 写整组
                 （addr=n_addr 且 qty=reg_count）；用 0x06 写其中单个寄存器会被拒绝
               - 线圈/离散输入（reg_type=1/2）只支持 reg_count=1

   位定义（可选字段，普通寄存器不用写，留空即 nil）：
   bits = { { bit=0, tag="运行状态" }, { bit=8, tag="故障报警" }, ... }
          适用场景：一个 16 位寄存器里装了多个开关量（厂商写法 768.08 = 寄存器768的bit8）
          说明：
          - 不写 / 写 nil 都合法，表示这个寄存器不做位解析
          - bit 从 0 开始（bit0 = 最低位）
          - 目前仅作为本地解析的参照信息保留，不参与协议映射，
            不会把位拆成独立的上行地址，也不影响轮询和从站响应
          - reg_type=1/2 的线圈/离散本身就是位地址，不使用 bits

4. 以下两个字段是「本地计算实际物理量」用的预留字段，不参与协议映射判断：
   data_type = u16 / i16 / u32 / i32 / f32 / string / bytes（SN 这类可写 string 或留空）
   scale_factor = 缩放系数，原始值 × scale_factor = 实际值
]]


-- 测试用点表
return {
    meta = {
        protocol_version = "xxxxxx_1.0.0",
        -- 接了几台从机，这些从机共用下面这一份 regs 模板
        slave_dev = {1},
    },

    -- 寄存器模板（每台 slave_dev 都会自动复制一份，dev_id 不同）
    regs = {
        -- num=1: something，holding，可读可写，单寄存器
        { num=1, tag="something1", s_addr=5000, n_addr=6400,
          reg_type=3, reg_count=1, data_type="u16", scale_factor=1, rw="rw"},

        -- num=2: 线圈，可读可写（测试 0x01 轮询 + 0x05 写穿透）
        { num=2, tag="coilDemo", s_addr=5100, n_addr=6500,
          reg_type=1, reg_count=1, data_type="bool", scale_factor=1, rw="rw"},

        -- num=3: 输入寄存器，长度2，只读
        { num=3, tag="multiInputReg", s_addr=5800, n_addr=7200,
          reg_type=4, reg_count=2, data_type="u32", scale_factor=1, rw="r"},

        -- num=4: 保持寄存器，长度4，可读可写
        { num=4, tag="multiHoldingReg", s_addr=756, n_addr=252,
          reg_type=3, reg_count=4, data_type="u64", scale_factor=1, rw="rw"},

        -- num=5: 设备 SN，输入寄存器，16 字节 = 8 个寄存器，字节串只读
        { num=5, tag="deviceSn", s_addr=123, n_addr=456,
          reg_type=4, reg_count=8, data_type="string", scale_factor=1, rw="r"},

        -- num=6: something，holding，可读可写，测试下行到设备的时候，跟num1连续读写
        { num=6, tag="something2", s_addr=5001, n_addr=6401,
          reg_type=3, reg_count=2, data_type="u32", scale_factor=1, rw="rw"},

        -- num=7: something，holding，可读可写，测试下行到设备的时候，跟num1连续读写
        { num=7, tag="something3", s_addr=5003, n_addr=6403,
          reg_type=3, reg_count=1, data_type="u16", scale_factor=1, rw="rw"},

        -- num=8: 测试线圈2，可读可写（地址跟num2连续读写）  
        { num=8, tag="coilDemo2", s_addr=5101, n_addr=6501,
          reg_type=1, reg_count=1, data_type="bool", scale_factor=1, rw="rw"},
          
        -- num=9: 测试线圈3，可读可写（地址跟num2连续读写）  
        { num=9, tag="coilDemo3", s_addr=5102, n_addr=6502,
          reg_type=1, reg_count=1, data_type="bool", scale_factor=1, rw="rw"},

        -- num=10: 测试离散输入A，只读  
        { num=10, tag="discreteInputA", s_addr=6000, n_addr=7000,
          reg_type=2, reg_count=1, data_type="bool", scale_factor=1, rw="r"},

        -- num=11: 测试离散输入B，只读  
        { num=11, tag="discreteInputB", s_addr=6001, n_addr=7001,
          reg_type=2, reg_count=1, data_type="bool", scale_factor=1, rw="r"},

        -- num=12: 测试离散输入C，只读  
        { num=12, tag="discreteInputC", s_addr=6002, n_addr=7002,
          reg_type=2, reg_count=1, data_type="bool", scale_factor=1, rw="r"},

        -- num=13: 测试离散输入D，只读  
        { num=13, tag="discreteInputD", s_addr=6010, n_addr=7010,
          reg_type=2, reg_count=1, data_type="bool", scale_factor=1, rw="r"},

          -- num=14: 测试机组状态，8个bit只读，长度为1输入寄存器
        { num = 14, tag = "测试机组状态", s_addr = 768, n_addr = 1000, reg_type = 4, 
          reg_count = 1, data_type = "u16", scale_factor = 1, rw = "r",
          bits = {
              { bit = 0, tag = "机组待机态" },
              { bit = 1, tag = "机组正在启动中" },
              { bit = 2, tag = "机组运行态" },
              { bit = 3, tag = "机组正在停机中" },
              { bit = 4, tag = "机组严重报警态" },
              { bit = 8, tag = "机组预热" },
              { bit = 9, tag = "机组有故障" },
              { bit = 10, tag = "机组防冻" },
          } },
    },
}




-- --定频机协议
-- return {
--     meta = {
--         protocol_version = "邦普_定频机", 
--         slave_dev = {1},
--     },

--     regs = {
--         --机组状态，8bit只读，长度为 [1] 输入寄存器
--         { num = 1, tag = "机组状态", s_addr = 768, n_addr = 1000, reg_type = 4, reg_count = 1, data_type = "u16", scale_factor = 1, rw = "r",
--           bits = {
--               { bit = 0, tag = "机组待机态" }, { bit = 1, tag = "机组正在启动中" }, { bit = 2, tag = "机组运行态" }, { bit = 3, tag = "机组正在停机中" },
--               { bit = 4, tag = "机组严重报警态" }, { bit = 8, tag = "机组预热" }, { bit = 9, tag = "机组有故障" }, { bit = 10, tag = "机组防冻" },
--           } },
--         -- --制冷控制温度, 32位浮点型数据，数据单位：℃，长度为 [2] 输入寄存器
--         -- { num = 2, tag = "制冷控制温度", s_addr = 6401, n_addr = 1001, reg_type = 4, reg_count = 2, data_type = "float", scale_factor = 0.1, rw = "r"},
--         -- --制热控制温度, 32位浮点型数据，数据单位：℃，长度为 [2] 输入寄存器
--         -- { num = 3, tag = "制热控制温度", s_addr = 6402, n_addr = 1003, reg_type = 4, reg_count = 2, data_type = "float", scale_factor = 0.1, rw = "r"},
--         --环境温度, 32位浮点型数据，数据单位：℃，长度为 [2] 输入寄存器
--         { num = 4, tag = "环境温度", s_addr = 6195, n_addr = 1005, reg_type = 4, reg_count = 2, data_type = "float", scale_factor = 0.1, rw = "r"},
--         --出水温度, 32位浮点型数据，数据单位：℃，长度为 [2] 输入寄存器
--         { num = 5, tag = "出水温度", s_addr = 1203, n_addr = 1007, reg_type = 4, reg_count = 2, data_type = "float", scale_factor = 0.1, rw = "r"},
--         --回水温度, 32位浮点型数据，数据单位：℃，长度为 [2] 输入寄存器
--         { num = 6, tag = "回水温度", s_addr = 6197, n_addr = 1009, reg_type = 4, reg_count = 2, data_type = "float", scale_factor = 0.1, rw = "r"},
--         --设定模式, 16位无符号整型只读，长度为 [1] 输入寄存器
--         { num = 7, tag = "设定模式", s_addr = 6400, n_addr = 1011, reg_type = 4, reg_count = 1, data_type = "u16", scale_factor = 1, rw = "r"},
--         --正在除霜压机数量, 16位无符号整型只读，长度为 [1] 输入寄存器
--         { num = 8, tag = "正在除霜压机数量", s_addr = 782, n_addr = 1012, reg_type = 4, reg_count = 1, data_type = "u16", scale_factor = 1, rw = "r"},
--         --水流开关运行状态, 1位bool只读，长度为 [1] 离散输入
--         { num = 9, tag = "水流开关运行状态", s_addr = 81, n_addr = 1013, reg_type = 2, reg_count = 1, data_type = "bool", scale_factor = 1, rw = "r"},
--        --机组累计运行时间, 16位无符号整型只读，长度为 [1] 输入寄存器
--         { num = 10, tag = "机组累计运行时间", s_addr = 6178, n_addr = 1014, reg_type = 4, reg_count = 1, data_type = "u16", scale_factor = 1, rw = "r"},
--        --通讯故障报警, 1位bool只读，长度为 [1] 离散输入
--         { num = 11, tag = "通讯故障报警", s_addr = 1168, n_addr = 1015, reg_type = 2, reg_count = 1, data_type = "bool", scale_factor = 1, rw = "r"},    
--        --开机命令, 1位bool可读可写，长度为 [1] 线圈
--         { num = 12, tag = "开机命令", s_addr = 0, n_addr = 1016, reg_type = 1, reg_count = 1, data_type = "bool", scale_factor = 1, rw = "rw"},
--         --停机命令, 1位bool可读可写，长度为 [1] 线圈
--         { num = 13, tag = "停机命令", s_addr = 1, n_addr = 1017, reg_type = 1, reg_count = 1, data_type = "bool", scale_factor = 1, rw = "rw"},
--         --复位命令, 1位bool可读可写，长度为 [1] 线圈
--         { num = 14, tag = "复位命令", s_addr = 8, n_addr = 1018, reg_type = 1, reg_count = 1, data_type = "bool", scale_factor = 1, rw = "rw"},
--         --模块设置, 16位整型可读写，长度为 [1] 保持寄存器
--         { num = 15, tag = "模块设置", s_addr = 6433, n_addr = 1019, reg_type = 3, reg_count = 1, data_type = "i16", scale_factor = 1, rw = "rw"},
--     },
-- }
