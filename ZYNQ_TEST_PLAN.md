# ZYNQ 侧测试计划（XC7Z020 demo 板）

> 本文是 **FPGA4dart 的 ZYNQ 阶段测试计划**：7A35T 上已经跑通的 PL 视觉管线，搬到 ZYNQ-7020
> 上做 demo，需要补做哪些测试、按什么顺序、每项的通过判据是什么。
> 姊妹文档：[README.md](README.md)（7A35T 现状）、[doc/vision_pipeline.md](doc/vision_pipeline.md)（设计细节）。
>
> **Scope (EN)**: what remains to be verified once the proven Artix-7 pipeline moves to a
> Zynq-7020 board — PS/PL interfaces (AXI-Lite registers, frame-end interrupt, VDMA/DDR path),
> bare-metal smoke tests in Vitis 2020.2, the PetaLinux 2020.2 main line that matches the dart
> target, actuators/IMU, end-to-end latency, resource fit **against xc7z010** (the real dart
> device, which is *smaller* than this demo board), and a regression/baseline routine.

---

## 0. 现状盘点：7A35T 上已经证明 / 尚未证明

**已证明（PL 侧，有仿真与上板证据）**

| 能力 | 证据 |
|---|---|
| 绿色圆靶识别全链路（分割 → 9×9 闭运算 → 双投影/团块跟踪 → 瞄准点） | `xsim` 自检 **129 项 ALL CHECKS PASSED**；上板 LCD 可见红环 + 十字 |
| 抗反光（相对饱和度闸 + 取外沿投影） | 测试台相位 2 眩光回归；现场"斜置屏幕"问题已复现并修复（P14） |
| 远/小目标、速度提前量、距离与下坠补偿（全部 1/w 查表，零除法） | 测试台相位 10~13；UART v3 帧逐字节核对（含 CRC16 + 帧序号） |
| 板上合成靶标自检（无相机/无灯可跑全链路） | `syn_target.v` + 状态页（`0x10`） |
| 运行时可调参数（不用重新综合） | `reg_file.v` UART `0xAA addr data (addr^data)`，19 个寄存器已接 |
| 资源与时序 | OOC 综合 LUT **7760 (37.3%)** / FF 3315 / DSP 27 / BRAM **24 RAMB36**（全来自 `temporal_acc`）；OOC WNS **+6.64 ns** |

**没证明（= 本文要补的）**

1. **PS/PL 接口一个都没做**：仓库里没有任何 AXI / VDMA / `processing_system7` / 中断代码
   （`rtl/`、`sim/` 全搜过了），只有注释里提过 dart 的 AXI4-Lite 做法。
2. **DDR3 通路必须换掉**：7A35T 上用的是**自研 DDR3 控制器**（`ddr3_top.v` / `ddr3_rw.v` /
   `ddr3_fifo_ctrl.v`）。ZYNQ 上 DDR3 归 PS（MIG 在 PS 里），PL **只能经 AXI HP 口 / VDMA** 访问 ——
   这不是"改个参数"，是数据通路的重新设计。
3. **视觉管线目前是"寄生"在 DDR3 读出 → LCD 写入之间**（输入 `rddata/rdata_req/rd_vsync`，
   输出直接进 `lcd_rgb_top`）。而飞镖上没有屏幕，ZYNQ 版本要把它变成**有自己 AXI 接口的 IP**。
4. **时钟域变了**：现在是 `lcd_clk` 25 MHz + `clk_out2` 50 MHz（50 MHz 是紧的域，
   `blob_track` 就曾在那里违例 5.2 ns）。ZYNQ 上没有 LCD 时管线时钟、相机 PCLK 域与 AXI 100 MHz 域
   三者之间的关系要重新定，**不是随便提频就能跑**。
5. **没有端到端时延数据**：UART 帧是 8 帧发一次（≈3.75 Hz@30fps），只能证明"功能对"，
   证明不了"延迟小"；飞镖的制导窗口约 1.5 s，延迟必须实测。
6. **没有舵机 / IMU / 图传 / 遥测**：这些是飞镖的必备项，7A35T 上完全没有。
7. **资源核算没按目标器件（xc7z010）做过**：7020 比 7010 大得多，**在这块板上跑通 ≠ 装得进飞镖的片子**。

---

## 0.1 开工前需要你确认的 5 件事

| # | 问题 | 为什么重要 | 不同答案的分支 |
|---|---|---|---|
| 1 | 7020 板的**具体型号** | 决定引脚约束、PS 配置、例程与文档来源 | **已识别为正点原子 ZYNQ 小系统板（MicroSYS），XC7Z020CLG400-2**；以官方例程/XDC 为基准 |
| 2 | 板上有**摄像头接口**（DVP/OV5640）吗？有 **LCD** 吗？ | 决定视觉输入源 | 无相机 → 用 `syn_target`（已有）或 DDR 回放做像素源；无 LCD → 连 LCD 通路一起砍掉 |
| 3 | 板上有 **以太网 PHY** 或 WiFi 吗？ | 决定图传/遥测走网口还是串口 | 无网口 → demo 阶段用 UART 上报（已有 `uart_parse.py`），图传留到飞镖真板 |
| 4 | 先做**裸机（Vitis）**还是直接上 **Linux（PetaLinux）**？ | 决定整个测试顺序 | 建议先裸机冒烟（1~2 天），再上 Linux；两者接口形状要一致（见 §2） |
| 5 | 有 **PetaLinux 2020.2 环境**吗（Ubuntu 18.04/20.04 虚拟机或 WSL）？ | 飞镖的软件栈是 PetaLinux 2020.2 | 本机只有 Windows 侧 Vivado/Vitis **2020.2**（已确认安装）；PetaLinux 需要 Linux 主机（本机装了 VMware Workstation，可用 Ubuntu 18.04 VM） |

> **板卡已确认**：正点原子 ZYNQ 小系统板（MicroSYS），`xc7z020clg400-2`。已交叉核对三处资料并完全一致：
> A盘 `ZYNQ_MicroSYS_IO.xdc`、`ZYNQ小系统开发板 IO引脚分配总表.xlsx`，以及根目录 `系统板原理图.pdf`
> （14 页 Altium 原理图，`11_IO.SchDoc` 的 LCD 连接器与 `Camera IO.xlsx`）。
>
> **重要硬件约束：摄像头接口与 LCD 接口共用 bank34 引脚。** 18-pin `CAMERA`（P1）排针与 42-pin
> `RGB TFTLCD` 排针在原理图上**并联**，12 个网络冲突：
>
> | 共用网络 | FPGA 脚 | LCD 信号 | 摄像头信号 |
> |---|---|---|---|
> | B34_L4_P | V12 | LCD_R0 | CMOS_D6 |
> | B34_L1_N | T10 | LCD_R1 | CMOS_SCL |
> | B34_L4_N | W13 | LCD_R2 | CMOS_D5 |
> | B34_L1_P | T11 | LCD_R3 | CMOS_SDA |
> | B34_L3_P | U13 | LCD_R4 | CMOS_D1 |
> | B34_L2_N | U12 | LCD_R5 | CMOS_VSYNC |
> | B34_L3_N | V13 | LCD_R6 | CMOS_D2 |
> | B34_L2_P | T12 | LCD_R7 | CMOS_HREF |
> | B34_L6_N | R14 | LCD_G0 | CMOS_D0 |
> | B34_L6_P | P14 | LCD_G2 | CMOS_RESET |
> | B34_L11_P | U14 | LCD_G5 | CMOS_D4 |
> | B34_L11_N | U15 | LCD_G7 | CMOS_D3 |
>
> 两个座**不能同时插满**：摄像头会丢掉 `D0-D6`、`VSYNC`、`HREF`、`SCL/SDA`、`RESET`；
> LCD 会丢掉红色全部 8 位和绿色 4 位。
>
> **解法**：板上有 `J7` / `J8` 两排 2×25P 排针，引出的是 **bank35 / bank13** 的独立引脚（不与 LCD 冲突）。
> 把摄像头用杜邦线改接到 **J7（bank35）**、LCD 继续留在 RGB LCD 座，两者即可共存。分配表见
> [prj/zynq_microsys.xdc](prj/zynq_microsys.xdc)（`cam_pclk` 特意选在 bank35 的 SRCC 脚 `L16` = J7-31；
> 外部 USB-TTL 串口用 J7-47/49）。**J8（bank13 + bank34 剩余）也可用**：J8-31/33/32/34 就是
> `B34_L8_P/N`、`B34_L10_N/P`，即摄像头原有的 `PCLK/D7/XCLK/PWDN` 网络。
>
> 该 XDC 只用于后续的 Zynq 顶层工程；当前 `ov5640_lcd.xpr` 仍是 XC7A35T 工程，不能加载它。
> Zynq 的 DDR3 由 PS 管理，不应沿用现有 PL MIG 引脚。

> 本机已确认：Vivado **2020.2** + Vitis **2020.2** + Vitis_HLS 2020.2（`D:\Xilinx\`），
> ModelSim SE-64（`D:\Modelsim\win64`）。xsim 与 ModelSim 都能用，与 7A35T 阶段一致。

---

## 1. 目标架构：ZYNQ 版本应该长什么样

```
        ┌────────────────────────── PL（7020 / 未来 7010） ──────────────────────────┐
OV5640  │ cmos_capture_data ─┬─► armor_vision ─┬─► overlay 叠印 ─► AXI4-Stream ─┐   │
  DVP ──┼─► (DVP→RGB565)     │   (现有管线)     │                              │   │
        │                    │                 ├─► [新] AXI4-Lite 结果寄存器 ──┼──►│ IRQ_F2P
        │                    └─► video_delay    └─► [新] frame_irq（帧末脉冲）  │   │
        │                                                                       │   │
        │  [新] pwm_6ch（6 路 PWM，复用 dart 的 IP）                             │   │
        │  [新] syn_target / DDR 回放（无相机时的像素源）                        │   │
        └───────────────────────────────────────────────────────────────────────┼───┘
                                                                                │
        ┌────────────────────────── PS（ARM + Linux 或裸机）──────────────────┐ │
        │ AXI GP ──► AXI-Lite 寄存器（读结果 / 写参数）                        │ │
        │ AXI HP/VDMA（S2MM）──► DDR3 ──► /dev/video0 ──► 图传（UDP/RTP-JPEG） │ │
        │ GIC ──► 驱动 ISR/tasklet ──► kfifo ──► 用户态 ioctl                  │ │
        │ SPI ──► BMI088（spidev）; I2C ──► 相机配置（二选一，见 §3-C4）       │ │
        │ PWM（AXI-Lite → sysfs）──► 4 路舵机                                  │ │
        │ 网口/WiFi ──► TCP 8080 遥测 + UDP 图传 + SD 卡记录                   │ │
        └─────────────────────────────────────────────────────────────────────┘ │
                                                                                ▼
                                                                       （AXI4-Stream → VDMA）
```

**与 7A35T 的三个关键差异**

| 项 | 7A35T（现在） | ZYNQ-7020（要做） |
|---|---|---|
| 帧缓冲 | 自研 DDR3 控制器（`ddr3_*.v`） | **PS 的 DDR3 + AXI HP 口 / VDMA**，自研控制器整个丢掉 |
| 结果上报 | UART 34 字节帧（v3，CRC16 + seq） | **AXI-Lite 寄存器 + 帧末中断**（UART 保留做旁路对拍） |
| 显示/消费方 | 4.3" LCD + 数码管 | **PS 侧软件**（飞镖上没有屏幕）；LCD/数码管只作调试 |

---

## 2. 接口对齐原则（最重要的一条）

飞镖的 PS 侧软件已经定型，它对 PL 的期望在 `dart2026_-open-source` 里写得非常具体：

| 飞镖软件的期望 | 对应文件 | 本工程要提供什么 |
|---|---|---|
| `/dev/video_manager`，ioctl：`VM_SET/GET_THRESHOLD`、`VM_GET_BOND_NUM`、`VM_GET_BONDS`、`VM_GET_FPS` | `dart_-application/.../preiph/video.h` | AXI-Lite 寄存器：阈值可写、结果可回读、帧率可读 + 帧末中断 |
| `VM_GET_BONDS` 返回**多目标**（`vm_bond_boxes_t`，最多 16 个 box，含 `squire` 面积） | 同上 | **决策点**：先按单目标对齐（`video_manager` 驱动当前快照也是单目标），多目标列为后续（见 §3-C6） |
| 阈值是 **R/G/B 三路**（`THRESHOLD_G/G_R/G_B`） | dart `video_manager_v1_0.v` | 本工程已有 `TH_G / TH_G-R / TH_G-B` 三个参数，直接映射；再加 `REL_SAT_PCT`（dart 没有，是本工程的优势，可留可关） |
| `/sys/bus/platform/devices/43c00000.pwm_6ch/chN_{arr,cmp,en}` | `dart_-application/.../preiph/servo.c` | 直接复用 dart 的 `pwm_6ch` IP + 驱动（6 路，13 个寄存器） |
| BMI088 走 `/dev/spidev0.0`（加速度）与 `/dev/spidev0.1`（陀螺） | `dart_-application/.../preiph/bmi088.c` | PS 的 SPI0 + `spidev`，不要写内核驱动（dart 就是这么做的） |
| 遥测 TCP 8080、图传 UDP 5004 | `dart_-application/.../preiph/network.c` | PS 侧网络，与 PL 无关；图传的像素源来自 VDMA/DDR |

**结论：ZYNQ 版本要"长得像 dart 的 `video_manager`"**，而不是另造一套接口。这样 7A35T 上验证过的
算法能直接接到 `dart_-application` 上跑，demo 才有意义。

**建议的 AXI-Lite 寄存器映射**（可直接照抄，字段来自现有 `result_frame` v3，一个不少）

| 偏移 | 名称 | 属性 | 内容 |
|---|---|---|---|
| `0x00` | `ID` | RO | 魔数 + 版本（如 `0xDA27_0001`），用来确认"真读到 PL 了" |
| `0x04` | `CTRL` | RW | b0 enable b1 irq_en b2 force_syn b3 bin_display b4 tacc_on b5 clear_irq |
| `0x08`~`0x3C` | 参数区 | RW | `TH_G / TH_GR / TH_GB / REL_SAT / MIN_SIZE / AIM_H_Q8(16bit) / RING_T+CROSS_L / GATE / HIT_LOST / LEAD_Q4 / DROP_SCALE / SYN_SPD / SYN_R` |
| `0x40` | `STATUS` | RO | b0 valid b1 far_small b2 moving b3 pred_ok b4 dist_ok b5 adapt_ok b6 tacc_on b7 syn_on |
| `0x44` | `OBS_XY` | RO | `{cy[15:0], cx[15:0]}`（当前观测外框中心） |
| `0x48` | `GEOM_XY` | RO | `{ay, ax}`（几何瞄准点） |
| `0x4C` | `SIZE` | RO | `{area>>7, w}`（外框宽 / 面积粗值） |
| `0x50` | `SHAPE` | RO | `{blob_cnt, fill_q8}` |
| `0x54` | `VEL` | RO | `{vy_q4, vx_q4}`（Q4 有符号，16 = 1 px/帧） |
| `0x58` | `PRED_XY` | RO | `{py, px}`（提前量后的预测灯心） |
| `0x5C` | `BALLISTIC` | RO | `{drop_px, dist_cm}` |
| `0x60` | `AIM_FINAL` | RO | `{fy, fx}` ← **云台/飞控直接用这个** |
| `0x64` | `SEQ_FPS` | RO | `{seq[7:0], fps[7:0]}` |
| `0x68` | `IRQ_STATUS` | RO/W1C | b0 frame_done b1 fifo_overflow b2 crc_err |
| `0x6C` | `DBG_STAT` | RO | 帧周期 / 掩膜像素数 / 命中率（`vision_stat` 的值）|

**中断约定**：帧末（结果寄存器更新完成）拉一个**单拍脉冲** → `xlconcat` → `IRQ_F2P` →
GIC → 驱动 `tasklet` 读寄存器 → `kfifo` → `waitqueue` → 用户态 `ioctl`（与 dart `video_manager` 同构）。
中断频率 = 结果更新率（默认每帧一次 = 30 Hz；若要降载就照 `result_frame` 的 `TX_DIV` 做分频）。

---

## 3. 测试项清单

> 判据一律写成**可观测**的形式：示波器/ILA 波形、串口打印、寄存器回读值、文件产物。
> "编译通过""能出图"都不算判据。

### A 组：板级与工具链基线（半天）

| # | 测什么 | 怎么做 | 通过判据 |
|---|---|---|---|
| A1 | 器件与器件树正确 | Vivado 里 `report_property [get_parts xc7z020*]`；确认板卡型号与 DDR3 容量 | 器件型号/速度等级与板上丝印一致；DDR3 容量写入 MIG 配置并有据可查 |
| A2 | PS 配置冻结 | 固化一份 `processing_system7` 配置：DDR3 型号与时钟、MIO 分配、`FCLK_CLK0=100MHz`、`IRQ_F2P`、AXI GP 口、UART1、SD0、以太网 | 配置截图 + 导出的 XSA 存档；后续所有测试都用这一份 |
| A3 | 启动链路 | SD 启动 + JTAG 下载两种方式都能跑 | 串口有完整启动日志；断电重上电可复现（连续 3 次） |
| A4 | 引脚约束重写 | 按 7020 板原理图重写 XDC（相机、按键、LED、串口、PWM 输出、时钟） | 引脚对照表逐条打勾；无 `unconstrained` 关键端口告警 |
| A5 | 时钟规划 | 定下三个域：相机 PCLK、AXI（100 MHz）、视觉管线（建议先沿用 25/50 MHz，别一上来就提频） | 时钟树图 + `report_clocks` 输出；跨域点清单（每处都要有 FIFO/握手） |

### B 组：裸机冒烟（Vitis 2020.2，1~2 天）——**先不碰视觉**

| # | 测什么 | 怎么做 | 通过判据 |
|---|---|---|---|
| B1 | Hello World + UART | Vitis 建 platform（用 A2 的 XSA）+ hello world | 串口打印正常；同一 XSA 能同时给 Vivado 与 Vitis 用 |
| B2 | **AXI-Lite 寄存器读写（不用写 C 也行）** | 先用 XSCT：`connect` → `targets` → `mrd 0x43C10000` / `mwr`（地址按你 BD 的实际分配） | 写进去读回来一致；`ID` 寄存器读到魔数 |
| B3 | 寄存器读写在软件里做 | 裸机 C 里 `Xil_Out32/Xil_In32` 遍历所有寄存器 | 全寄存器读写一致；非法地址不挂死（加超时/保护） |
| B4 | 中断链路 | PL 先放一个可控的"每秒 1 次"脉冲（或直接用 AXI 定时器）→ `xlconcat` → `IRQ_F2P` → GIC | ISR 里计数：1 分钟误差 < 1%；`IRQ_STATUS` 的 W1C 能清干净、不丢不重 |
| B5 | DDR 带宽基线 | PS 侧裸机 `memtest` + 简单 AXI master 写 DDR | 记录实测 MB/s（读/写/混合）作为后续 VDMA 的对照上限 |
| B6 | VDMA/帧通路（可选先做） | `syn_target` 或测试图案 → AXI4-Stream → VDMA S2MM → DDR | 用 Vitis 的 Memory Viewer 看到**一帧完整图案**；行宽/像素格式与预期一致 |
| B7 | GPIO/ILA 打点就绪 | 把"帧开始""结果更新""中断"三个事件引到 GPIO 或 `system_ila` | ILA 能抓到三个事件的相对时刻（后面 §5 要用） |

### C 组：PL 迁移与接口实现（这是主体，3~6 天）

| # | 测什么 | 怎么做 | 通过判据 |
|---|---|---|---|
| C1 | 视觉管线原样搬到 7020 | 保留 `armor_vision` 全部参数与默认值（所有 P0~P14 开关**默认关闭**的状态），先不接 AXI | OOC 综合 0 error / 0 warning / 0 latch；资源数字与 7A35T 阶段同量级（LUT ≈7.8K） |
| C2 | 用 `syn_target` 自检 | `0x0F=1` 打开合成靶标，跑全链路 | 结果寄存器/串口上报的 `cx` 按合成速度移动，`vx_q4` 与设定值对得上（这正是 `syn_target` 存在的意义：**不用相机就能验 AXI + 中断 + 时延**） |
| C3 | AXI-Lite 寄存器文件 | 新写 `vision_regs_axi.v`（照 dart 的 `*_S00_AXI.v` 风格），把 §2 的表实现出来 | 每个寄存器：从 PS 写→RTL 内生效；RTL 结果→PS 读到；`ID` 正确 |
| C4 | 相机配置走哪条路 | 方案 a：**保留 PL 的 `i2c_dri` + `i2c_ov5640_rgb565_cfg`**（最快，不碰 Linux 驱动）；方案 b：PS I2C + Linux ov5640 驱动（更像飞镖） | 方案 a：LCD/寄存器能出图即通过；方案 b：`v4l2-ctl --list-formats` 认到传感器且能出帧 |
| C5 | 帧末中断 | 帧末单拍脉冲 → `IRQ_F2P`；先在裸机 ISR 里计数，再在 Linux 驱动里计数 | 中断频率 = 帧率（±1%）；连续 10 万帧不丢（丢就让 `IRQ_STATUS.frame_done` 与 `seq` 都能发现） |
| C6 | 单目标 → 多目标的决策 | 先做单目标（对齐 `video_manager` 当前快照）——把 `blob_track` 的"最大团块"结果放寄存器；多目标列入下一阶段 | 本阶段：单目标寄存器路径通过 C2/C3/C5；多目标：**明确写下取舍与理由**（需上完整 CCL，可移植 dart 的 `FindBond.v`） |
| C7 | **UART 与 AXI 两条路对拍** | 同一帧：UART v3 帧（已有 CRC16 + seq，PC 端 `tools/uart_parse.py` 解析）与 AXI 寄存器同时读 | 连续 ≥1000 帧，两条路的 `cx/cy/ax/ay/w/dist/drop/fx/fy/flags/seq` **逐字节一致**（这是证明 AXI 通路没有错位/漏帧的最强证据） |
| C8 | 时序收敛 | 在 A2 定的时钟下跑实现 | WNS ≥ 0；若提频到 100/150 MHz 必须重做（`blob_track` 在 50 MHz 就违例过，靠三级流水才过）——**先记基线，再谈提频** |

### D 组：Linux 主线（对齐飞镖软件栈，3~7 天，需 Linux 主机）

| # | 测什么 | 怎么做 | 通过判据 |
|---|---|---|---|
| D1 | PetaLinux 2020.2 环境 | Ubuntu 18.04/20.04 VM（本机有 VMware）安装 PetaLinux 2020.2（与 Vivado/Vitis 2020.2 同版本） | `petalinux-util --version` 正常；能 `petalinux-create` 出工程 |
| D2 | 工程基于 7020 的 XSA 建起来 | `petalinux-config --get-hw-description=<XSA>`；**可直接借用 dart 的 `dart_-linux/project-spec/meta-user/` 里的配方**（驱动 recipe、设备树片段、U-Boot 配置） | 生成 BOOT.BIN + image.ub；串口登录 root |
| D3 | 自研驱动：`video_manager` | 移植 dart 的 `video_manager.c`（中断 → tasklet 读寄存器 → kfifo → 唤醒队列）到本工程的寄存器映射 | `/dev/video_manager` 出现；`ioctl` 五个命令全部可用；`read()` 阻塞/非阻塞都对 |
| D4 | 自研驱动：`pwm_6ch` | 直接复用 dart 的 IP + 驱动（sysfs 属性） | `/sys/.../ch0_{arr,cmp,en}` 可读写；示波器看到周期/占空比跟着变 |
| D5 | 设备树 | 加 `pl-custom.dtsi` 节点：`video_manager`（含 `interrupts`）、`pwm_6ch`、SPI（spidev）、I2C、VDMA/vcap | `dmesg` 里 probe 成功；`/proc/interrupts` 里能看到中断计数在涨 |
| D6 | IMU | BMI088 挂 SPI0，`spidev0.0` / `spidev0.1`，Mode3 1 MHz；先裸读寄存器 | 读到正确的 `CHIP_ID`（加速度 0x1E / 陀螺 0x0F）；连续采样 1 kHz 不丢（打时间戳测抖动） |
| D7 | 图传与遥测 | VDMA → DDR → `/dev/video0` → GStreamer（`jpegenc ! rtpjpegpay ! udpsink`）→ PC 上位机；TCP 8080 遥测 | PC 端看到画面；遥测变量表 + 数据包能被 `NetworkClient.py` 解析 |
| D8 | 应用层联调 | 把 `dart_-application` 编进 rootfs（或交叉编译后 scp 上去） | `task_video` 能取到 box；`task_imu` 能出姿态；`task_control` 能算出舵机角并写到 PWM；`Servo_Config.txt` 能读到 |

### E 组：执行机构与传感器（与 D 组并行，1~2 天）

| # | 测什么 | 怎么做 | 通过判据 |
|---|---|---|---|
| E1 | 6 路 PWM → 舵机 | 参数对齐飞镖：333 Hz、500–2500 µs（`servo.h`）；四路分别扫 0/90/180 | 示波器测脉宽误差 < ±10 µs；四个舵机都能到位、不抖 |
| E2 | 舵机与视觉的联动 | 用视觉结果的 `fx` 做一个最简比例控制写进 PWM | 灯移动时舵机跟着动；端到端能看到"视觉 → 舵机"闭环（哪怕增益是拍的） |
| E3 | IMU + 姿态解算负载 | PS 上跑 QEKF（dart 是 1 kHz） | CPU 占用有记录；1 kHz 下无异常 dt（`ins.c` 里对 dt 有钳制，看它有没有频繁触发告警） |
| E4 | 热与供电 | 连续跑 1 h，记录 SoC 温度与 5 V 域电流 | 温度稳定（dart 实测结温 44.5 °C 可作参考）；无掉电复位 |

### F 组：系统级指标（demo 的"成绩"）

| # | 测什么 | 怎么做 | 通过判据（建议目标） |
|---|---|---|---|
| F1 | **端到端时延** | §5 的方法：相机帧起始 → 结果寄存器更新（PL 打点）→ 中断 → 用户态读到 | 视觉侧 < 1 帧（<33 ms）；PL 内部 < 1 ms；**"像素进 → 用户态拿到"总计 < 40 ms**（写清测量方法，别只给一个数） |
| F2 | 结果更新率 | 寄存器 `SEQ_FPS` + ILA 计数 | 稳定帧率（当前 30 fps 量级）；±2% 以内 |
| F3 | 识别率与误检 | 用真实靶标（绿圆灯）在 0.7~5 m 逐档测，每档 ≥100 帧 | 各档 `valid` 命中率 ≥ 95%；空场景误检 = 0 |
| F4 | 反光/斜置回归 | 复现 7A35T 上的"斜置 + 反射"场景 | 与 7A35T 结论一致（框不炸、`valid` 不丢）；若不一致，说明 ZYNQ 版像素时序有偏移，回 C1 |
| F5 | 稳定性 | 连续 1 h 跑视觉 + 中断 + 遥测 + 记录 | 无丢帧累积（`seq` 连续）、无死机、内存不涨 |
| F6 | 断电恢复 | 反复上电 5 次，每次都完整自检 | 5/5 成功；自检脚本给出 PASS/FAIL |

### G 组：回归与基线固化

| # | 测什么 | 怎么做 | 通过判据 |
|---|---|---|---|
| G1 | 保留两个仿真通道 | ① `sim/run_vision_sim.bat`（129 项自检，8~10 min）② 秒级单测（`tb_tacc.v` / `tb_p13.v`） | 每次改 RTL 前后都跑；数字不退化 |
| G2 | 给新 RTL 补 TB | 给 `vision_regs_axi` 写自检 TB（读写遍历 + 中断脉冲 + W1C），并入一键脚本 | TB 自检项 ≥20，5 秒内跑完 |
| G3 | 自动化 | 把 §3 的判据里能自动化的部分（寄存器遍历、中断计数、UART/AXI 对拍、fps 统计）做成脚本 | 一条命令出 PASS/FAIL 报告 |
| G4 | 归档 | 每次上板：XSA、bit、报告（时序/资源）、测试记录表、原始数据 | 目录结构固定；能一眼看出"哪一版、什么结论" |

---

## 4. 资源核算：必须在 **xc7z010** 上也能过

demo 板是 7020，**飞镖的片子是 7010**（报告里写的是 XC7Z010-CLG400）。已在 7010 上落地的 dart 设计用了：
**LUT 68.28%、FF 43.24%、BRAM 40.83%**（报告实测）。器件容量（据 Xilinx 数据手册，丢进 Vivado 再核一次）：

| 器件 | LUT | FF | BRAM (RAMB36) | DSP |
|---|---|---|---|---|
| XC7A35T（当前板） | 20,800 | 41,600 | 50 | 90 |
| **XC7Z010（飞镖目标）** | **17,600** | **35,200** | **60** | **80** |
| XC7Z020（demo 板） | 53,200 | 106,400 | 140 | 220 |

**结论与动作**

1. 本工程视觉 add-on 自身约 **LUT 7.8K**（OOC），BRAM 用量取决于 `temporal_acc`：
   **`TACC_EN=1` 要 24 个 RAMB36（在 7010 上是 40%！）**，`TACC_EN=0` 时几乎不占 BRAM（走 LUTRAM）。
   → **上 7010 时 `TACC_EN` 必须保持 0**（它本来就默认关），否则和 dart 原有逻辑抢 BRAM。
2. dart 在 7010 上已经用掉 68% LUT：把本工程管线（+7.8K LUT）整个塞进去**会超**。
   → ZYNQ 版本的定位应该是**"替代而不是叠加"**：本管线的形态学 + 投影/团块跟踪，
   与 dart 的 `Threshold_ip` + `FindBond` **是同一层功能**，只保留一套。
3. 定一条规矩：**每个里程碑都要补一次 `xc7z010clg400-1` 的 OOC 综合报告**
   （`tools/synth_check_vision.tcl` 改一下 `-part` 即可），并把数字贴进测试记录。
4. 7020 上"资源宽裕"是假象（4 倍 LUT、2.3 倍 BRAM），别用它的余量做设计决策。

---

## 5. 端到端时延怎么测（别只报一个数）

三个层次分开测，全部用同一次触发对齐：

| 层次 | 方法 | 期望量级 |
|---|---|---|
| ① PL 内部（像素 → 结果寄存器更新） | 用 `system_ila` 同时抓"帧起始（`vsync`/`tduser`）"与"结果更新脉冲"；或把两个事件引到空闲 GPIO，用示波器测 | 亚毫秒（管线是流水的） |
| ② 中断 + 驱动（结果更新 → 用户态拿到） | 在 ISR 入口翻转一个 GPIO，用户态读完后再翻转另一个 → 示波器测脉宽；或在内核里用 `ktime_get_ns()` 打时间戳 | 几十 µs 量级（含 tasklet + 唤醒 + 系统调用） |
| ③ 相机曝光 + 读出（真实的光 → 数字） | 用 `syn_target` 时不受曝光影响，**接真相机时必须单独算**：曝光时间（可读回寄存器）+ 帧周期 | 一个帧周期量级（30 fps ≈ 33 ms） |

**为什么要拆**：飞镖窗口只有约 1.5 s，"识别 30 fps"这个数字说明不了延迟；
真正要吃的是 ③（曝光 + 读出）——这也是 dart 报告里"帧率跟随相机"那句话的含义。

---

## 6. 已知坑（本工程踩过的 + ZYNQ 特有的）

**本工程已经踩过、ZYNQ 阶段同样会遇到的**

1. **`.v` / `.xdc` 是 GBK 编码**，`doc/*.md`、`tools/*.py` 是 UTF-8。批量改 `.v` 必须走 Python
   （GBK 解码 → 改 → GBK 写 → 回读比对），**不要用会猜编码的编辑器**（会写出 U+FFFD 不可逆损坏；
   `reg_file.v`、`osd_text.v` 的历史注释已经坏过一次）。
2. **Vivado 开着时外部改 `.xpr` 会被静默抹掉** → 新增源文件只能在 Tcl Console 里
   `source tools/add_sources_vivado.tcl`；命令行自查 `python tools/check_xpr_sources.py`。
3. **行缓冲 / 存储器一律走 `line_buffer.v` 模板**（同步写 + `assign dout = mem[raddr]`）：
   写错会导致 LUT 15747 / FF 21684 的爆炸。
4. **多驱动**：同一 `reg` 被两个 `always` 写，**xsim 容忍、Vivado 报 `[DRC MDRV-1]` 拒绝** →
   "仿真过"不等于"能实现"。
5. **固定曝光默认关**（`CAM_LOCK_EN=1'b0`）：标错就是黑屏；本工程的抗反光靠算法，不靠相机设置。
6. **提频要重新收敛**：50 MHz 上 `blob_track` 就违例过（拆三级流水才过）。

**ZYNQ 特有的**

7. **自研 DDR3 控制器必须删掉**：PS 的 DDR 不能被 PL 直接当 SRAM 用，PL 侧要走 AXI HP（或 VDMA）。
8. **DDR 带宽是共享资源**：CPU、VDMA、图传、DMA 都在抢；先测基线（B5）再谈多路并行。
9. **Linux 下的 DMA 缓存一致性**：VDMA/v4l2 走 DMA，用户态读之前要有 `dma-buf`/`mmap` 的正确姿势；
   先照 dart 的做法（vcap + v4l2 + GStreamer），别自己野路子 map 物理地址。
10. **PL 寄存器访问要加边界与超时**：AXI 访问非法地址在裸机上直接挂死；寄存器读回要校验。
11. **中断别在 ISR 里干活**：照 dart 的形态（ISR/tasklet 只搬数据 → kfifo → 用户态），
    否则帧率一高就会丢中断。
12. **设备树里的 `interrupts` 号要对**：dart 是 `interrupts = <0 29 1>`（IRQ_F2P 的第 0 号经 xlconcat）。
    7020 版按你的 BD 实际连接写，写完用 `/proc/interrupts` 验证计数在涨。

---

## 7. 建议顺序与里程碑

| 里程碑 | 内容 | 依赖 | 预计 |
|---|---|---|---|
| **M0** | 确认 §0.1 的 5 件事；冻结 PS 配置（A1~A3） | — | 0.5 天 |
| **M1** | 裸机冒烟（B1~B4）：ID 寄存器能被 XSCT/裸机读写、中断能数 | M0 | 1 天 |
| **M2** | 无相机自检（C2）：`syn_target` → 寄存器 → 中断 → 裸机读到正确的运动学量 | M1 | 1~2 天 |
| **M3** | AXI-Lite 寄存器文件 + 中断正式化（C3/C5），UART/AXI 对拍（C7） | M2 | 2~3 天 |
| **M4** | 接相机（C4 方案 a）+ 反光回归（F4） | M3 | 1~2 天 |
| **M5** | 帧通路到 DDR + 图传（B6/D7） | M1 | 1~2 天 |
| **M6** | Linux 主线（D1~D6）：驱动、设备树、PWM、IMU | M0（Linux 环境） | 3~5 天 |
| **M7** | 应用联调（D8）+ 端到端时延（F1）+ 长稳（F5） | M3~M6 | 2~3 天 |
| **M8** | 按 xc7z010 的资源核算与收口（§4）+ 归档（G4） | 每个里程碑都做 | 持续 |

**最短可用 demo（如果时间紧）**：M0 → M1 → M2 → M3 → M4，即
"**没有 PS 软件栈，也能在 7020 上用 AXI 寄存器 + 中断把视觉结果交给 ARM，并证明延迟**"。
这条线的价值是：它验证了飞镖最核心的 PL↔PS 契约，其余（Linux 驱动、图传、舵机）都是可复用的既有资产。

---

## 8. 测试记录表（复制到每轮上板记录里）

| 编号 | 测试项 | 日期 | 版本（XSA/bit 哈希） | 结果 | 证据文件 | 备注 |
|---|---|---|---|---|---|---|
| A1 | | | | | | |
| B2 | | | | | | |
| C2 | | | | | | |
| C7 | | | | | | |
| F1 | | | | | | |
| …  | | | | | | |

> 判据写"通过/不通过 + 证据路径"，不写"正常/OK"。

---

## 9. 未决问题（随测试推进逐条销号）

- [ ] 7020 板型号与官方例程路径（决定 PS 配置与 XDC 来源）
- [ ] 板上有无 DVP 相机接口 / 有无 LCD（决定 C4 与是否保留显示通路）
- [ ] 有无以太网 PHY / WiFi（决定 demo 是否包含图传）
- [ ] 先裸机还是直接 Linux（§0.1 第 4 条）
- [ ] PetaLinux 2020.2 运行环境（VM 还是 WSL；本机 WSL 被沙箱挡住无法确认）
- [ ] 单目标 vs 多目标（C6）：本阶段是否只做单目标
- [ ] 是否把 `AIM_H_Q8` 从 8 位提到 16 位（现有寄存器表里 `r_aim_h` 仍是 8 位 = 116，
      真实需求是 **372**；dart 的参数是 16 位 —— 这是一处**已知不一致**，建议在 AXI 映射里直接给 16 位）
- [ ] 管线时钟最终取多少（先 25/50 MHz 基线，还是一步到 100 MHz）
- [ ] 谁来提供真实靶标（绿圆灯）做 F3/F4 的现场测试
