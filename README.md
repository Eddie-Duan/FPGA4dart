# FPGA4dart

**English** ｜ [简体中文](#简体中文说明) ｜ [繁體中文](#繁體中文說明)

A bold attempt at using FPGA / ZYNQ to enable the **DART robot** in RoboMaster.
This repository currently contains a **pure-Verilog vision pipeline** (no neural network):
the dart target is **one big green circular lamp**, so the pipeline segments green, cleans it up
with morphology, locates the circle by **dual projection**, and draws a **red ring + center cross**
onto a 4.3" RGB LCD. A 6-digit 7-segment display shows the three color thresholds live.

Built on top of the ALIENTEK (正點原子) Da Vinci **XC7A35T** example project *39_ov5640_lcd*
(`OV5640 → DDR3 frame buffer → RGB LCD`).

```
OV5640 (RGB565 800×480) → DDR3 ping-pong buffer → [ green seg → morphology → dual projection → overlay ] → LCD
                                                                                    └→ 6-digit 7-seg
```

| | |
|---|---|
| **Board** | ALIENTEK Da Vinci XC7A35TFGG484-2 (Artix-7: 20,800 LUT / 41,600 FF / 1,800 Kb BRAM / 90 DSP) |
| **Camera** | OV5640, RGB565, 800×480 |
| **Display** | 4.3" RGB LCD, 800×480, pixel clock 25 MHz (1:1, no scaling) |
| **Tool** | Vivado 2020.2 |
| **Verification** | `xsim` self-checking testbench — 33/33 checks pass |
| **Synthesis** | 0 errors / 0 warnings / 0 latches — LUT 3275 (15.8%), FF 787 (1.9%), LUTRAM 2082, DSP 4, BRAM 0 |
| **Reference** | color judgment borrowed from the dart2026 open-source FPGA IP (`Threshold.v`) |
| **License** | MIT (see [LICENSE](LICENSE)) |

### Repository layout

```
FPGA4dart/
├── rtl/            # Verilog sources (GBK encoded, see "Encoding" below)
├── sim/            # testbench + one-click xsim script
├── prj/            # Vivado project (ov5640_lcd.xpr + ov5640_lcd.srcs)
├── doc/            # design notes, block diagram source, synthesis reports
│   └── vision_pipeline.md      # deep-dive design document (Chinese)
├── tools/          # dev scripts (sim / synth / encoding / path checks)
├── _backup_before_vision/      # stock example files, for rollback
└── _backup_before_green/       # files from before the green-target change
```

### Quick start

```powershell
# 1) RTL simulation (no DDR3 / IP needed, ~1 minute)
cd sim
.\run_vision_sim.bat

# 2) Resource check (out-of-context synthesis of the vision pipeline)
vivado -mode batch -source tools/synth_check_vision.tcl

# 3) On the board
#    open prj/ov5640_lcd.xpr → Generate Output Products → Run Synthesis
#    → Run Implementation → Generate Bitstream → Program device
```

Keys: `key[0]` pick which threshold to tune · `key[1]`/`key[2]` ±8 · `key[3]` binary view.
LEDs: `led[0..2]` which threshold is selected · `led[3]` target detected (solid) / not detected (blinks).
7-segment: `[1/2/3] 000  0 0` = selected threshold id, its value, and blob width ÷ 10.

---

## 简体中文说明

> 飞镖（dart）的靶标是**一个大绿色圆形灯**。本工程在官方 **39_ov5640_lcd** 例程的
> 「DDR3 读出」与「LCD 写入」之间插入一条纯 Verilog 视觉管线：绿色分割 → 形态学闭运算 →
> **双投影找绿块** → 红色圆环 + 中心十字，并把三个颜色阈值显示在板载 6 位数码管上。
> 深入设计说明（时序关系、双投影原理、Vivado LUTRAM 推断踩坑）请看 **[doc/vision_pipeline.md](doc/vision_pipeline.md)**。

### 1. 功能

| 功能 | 说明 |
|---|---|
| 绿色分割 | RGB565 → 1bit 二值图，判据 `G>=TH_G && G-R>=TH_G-R && G-B>=TH_G-B`（借自 dart 的 `Threshold.v`） |
| 形态学去噪 | 9×9 膨胀 → 9×9 腐蚀 = **闭运算**，填补绿圆内部小洞、去掉碎点 |
| 目标定位 | **双投影**：X 直方图找最宽的连续亮列 run → 左右边界；Y 直方图找最长的连续亮行 run → 上下边界 |
| 圆形状校验 | 宽高都 ≥ `MIN_SIZE`、宽高比在 2:1 内、峰列高度 ≥ 3/4 高 —— 挡掉反光块 / 杂色块 |
| 标记输出 | **红色圆环**（半径 = (宽+高)/4，环宽 ±`RING_T`）+ 中心十字；另可切纯二值图模式方便调阈值 |
| 数码管 | 6 位共阳数码管实时显示「阈值编号 + 选中阈值(000~255) + 目标宽度/10」 |
| 状态指示 | 4 颗 LED：当前在调哪个阈值（3 颗）、检测到目标（常亮 / 未检测到时 1.5Hz 闪） |

### 2. 硬件与环境

| 项目 | 内容 |
|---|---|
| FPGA | 正点原子达芬奇 **XC7A35TFGG484-2**（20,800 LUT / 41,600 FF / 1,800Kb BRAM / 90 DSP） |
| 相机 | OV5640，RGB565，800×480（DVP 接口） |
| 显示 | 4.3 寸 800×480 RGB LCD（`lcd_id` = `0x7084` / `0x4384`，像素时钟 25 MHz） |
| 数码管 | 板载 6 位共阳数码管：`seg_sel[5:0]` 位选（低电平选通）、`seg_led[7:0] = {dp,g,f,e,d,c,b,a}`（低电平点亮） |
| 开发工具 | Vivado 2020.2（仿真器 xsim） |
| 按键引脚 | `key[3:0]` = T1 / U1 / W2 / T3（**低电平有效**） |
| LED 引脚 | `led[3:0]` = R2 / R3 / V2 / Y2（**低电平点亮**） |
| 数码管引脚 | `seg_sel[5:0]` = J15 / H17 / H13 / G17 / H18 / G18；`seg_led[7:0]` = H15 / G16 / L13 / G15 / K13 / G13 / H14 / J14 |
| 复位 | `sys_rst_n` = U2 |

### 3. 目录结构

```
FPGA4dart/
├── rtl/                 # Verilog 源代码（GBK 编码）
│   ├── armor_vision.v   #   视觉管线顶层
│   ├── color_seg.v      #   绿色分割（纯组合逻辑）
│   ├── morph_nxn.v      #   N×N 膨胀 / 腐蚀
│   ├── line_buffer.v    #   单行缓冲（LUTRAM 标准模板）
│   ├── video_delay.v    #   像素流延迟（原图对齐）
│   ├── proj_bond.v      #   双投影找绿块 + 边界框 / 圆心
│   ├── overlay_box.v    #   红色圆环 + 中心十字
│   ├── seg_display.v    #   6 位数码管驱动
│   ├── vision_cfg.v     #   按键 → 三个阈值 / 显示模式
│   ├── key_debounce.v   #   按键同步 + 消抖 + 按下沿
│   └── (官方 39 例程原有的 13 个文件)
├── sim/                 # tb_armor_vision.v + run_vision_sim.bat（一键 xsim）
├── prj/                 # ov5640_lcd.xpr + ov5640_lcd.srcs（IP 的 .xci 都在）
├── doc/                 # vision_pipeline.md、框图 vsdx、综合资源报告
├── tools/               # 开发脚本（见第 12 节）
├── _backup_before_vision/   # 未加入视觉前的原始 39 例程文件（还原用）
└── _backup_before_green/    # 改成绿色靶标前的文件（还原用）
```

> 注：`.gen` / `.runs` / `.hw` / `.sim` / `.cache` / `.ip_user_files` 这些**可由源代码重建**的目录没有纳入版本控制（见 `.gitignore`）。
> 第一次打开 Vivado 工程时它会自动重新生成 IP output products。

### 4. 系统架构

```mermaid
flowchart TD
    IN["DDR3 读出<br/>rddata / rdata_req / rd_vsync"] --> ALIGN["输入对齐<br/>（打一拍）"]
    ALIGN --> SEG["color_seg<br/>绿色分割"]
    SEG --> DIL["morph_nxn 9×9<br/>膨胀"]
    DIL --> ERO["morph_nxn 9×9<br/>腐蚀（= 闭运算）"]
    ERO --> MASK["mask_d 二值图"]
    ALIGN --> DLY["video_delay<br/>延迟 8 行 + 8 像素"]
    MASK --> PROJ["proj_bond<br/>双投影<br/>最宽列 run / 最长行 run"]
    MASK --> MIX["显示合成"]
    DLY --> MIX
    PROJ --> OVL["overlay_box<br/>红色圆环 + 中心十字"]
    PROJ --> SEGD["seg_display<br/>6 位数码管"]
    OVL --> MIX
    MIX --> LCD["4.3 寸 RGB LCD 800×480"]
```

**三个关键设计决定**

1. **用双投影取代连通域标记（CCL）**：靶标只有**一个**大绿圆，X / Y 两个 1D 直方图就能把它框住。
   资源只要 `800×10bit + 480×10bit` 的 LUTRAM，没有等价类合并、label 回收这些容易出错的逻辑，
   调试时直方图数值可以直接看。（dart 工程用的是完整 CCL `FindBond.v`，本工程是它的轻量替代。）
2. **形态学窗口是「右下角对齐」**：二值图在屏幕上会整体往右下偏移 `N-1 = 8` 像素，
   所以用 `video_delay` 把**原图也延迟 8 行 + 8 像素**，两者在屏幕上完全对齐，圆环才不会画歪。
3. **环与十字画在同一像素流坐标上**：`proj_bond` 统计出来的坐标就是屏幕坐标，`overlay_box` 直接比对，
   不需要额外坐标转换。

**时间关系**：直方图在有效显示行累加；帧末（`rd_vsync` 后的垂直消隐）先扫 X（801 拍）再扫 Y（481 拍），
共约 1283 拍；垂直消隐有约 47000 拍（1056 × 45），非常宽裕。
X 与 Y 在**同一帧**算完，所以**框不再慢一帧**（第一帧末就能出框）。

### 5. 仿真验证

```powershell
cd sim
.\run_vision_sim.bat
# 等同于： xvlog <设计文件...> ; xelab -debug typical tb_armor_vision -s tb_vision ; xsim tb_vision -runall
```

测试台造出与 `lcd_driver`（800×480 面板）**完全相同**的时序，图像为
**一个绿色实心圆**（圆心 (400,240)、半径 100、`RGB565 = 0x750E` → `r8=118 g8=162 b8=118`，
即 `G-R = G-B = 44`），并验证 33 项：

| 阶段 | 检查 | 期望 | 说明 |
|---|---|---|---|
| 1 | `bond_l` / `bond_r` | 309 / 507 | 圆心 + 形态学偏移 8 后是 (408,248)，半径 100 |
| 1 | `bond_t` / `bond_b` | 149 / 347 | 上下同理 |
| 1 | `center_x` / `center_y` | 408 / 248 | 圆心 |
| 1 | `bond_w` | 199 | 投影阈值 `TH_MIN=24` 让左右各内缩 1 像素 |
| 1 | `inside_green` | `0x750E` | 圆内：命中 → 保持原色（不变暗） |
| 1 | `bg_dim` | `0x4208` | 圆外背景：未命中 → 亮度减半 |
| 1 | `ring_red` / `center_red` | `0xF800` | 圆环上 (507,248) 与圆心都是红色标记 |
| 2 | `sel` | 1 | 按 `key[0]` 一次 → 选中项切到 `TH_G-R` |
| 3 | `th_gr` / `bond_valid` | 48 / 0 | 按 `key[1]` 两次 → `TH_G-R` 48 > 44 → **目标丢失** |
| 4 | `th_gr` / `bond_valid` | 32 / 1 | 按 `key[2]` 两次 → 阈值回来 → **恢复检测** |
| 5 | `sel` | 2 | 再按 `key[0]` 一次 → 选中项切到 `TH_G-B` |
| 6 | `disp_bin` / `bin_white` | 1 / `0xFFFF` | 按 `key[3]` → 纯二值模式，圆内显示白色 |

实测输出：`==== ALL CHECKS PASSED ====`（33 项）。

> 期望值的推导：形态学窗口「右下角对齐」，膨胀+腐蚀后二值图整体往右下偏 8 像素，
> 所以二值图上圆心是 (400+8, 240+8) = (408,248)、半径仍是 100。
> 投影阈值 `TH_MIN=24`：一列的弦长 `2*sqrt(100²-d²) >= 24` 要求 `|d| <= 99`，
> 于是左右 = `408±99` = [309,507]、上下 = `248±99` = [149,347]，宽高都是 199。

### 6. 按键 / LED / 数码管

绿色判据有**三个**阈值（`TH_G`、`TH_G-R`、`TH_G-B`），所以 `key[0]` 改成「选哪个阈值」，
`key[1]`/`key[2]` 对选中的那一颗做加减：

| 按键 | 引脚 | 功能 |
|---|---|---|
| `key[0]` | T1 | 循环选择要调的阈值：`TH_G` → `TH_G-R` → `TH_G-B` → `TH_G` |
| `key[1]` | U1 | 当前选中的阈值 +8（上限 255） |
| `key[2]` | W2 | 当前选中的阈值 −8（下限 0） |
| `key[3]` | T3 | 显示模式切换（0 = 原图变暗+标记；1 = 纯二值图） |

| LED | 引脚 | 含义 |
|---|---|---|
| `led[0]` | R2 | 当前在调 `TH_G` |
| `led[1]` | R3 | 当前在调 `TH_G-R` |
| `led[2]` | V2 | 当前在调 `TH_G-B` |
| `led[3]` | Y2 | 检测到目标常亮；未检测到时 1.5 Hz 闪烁（顺便当心跳） |

**6 位数码管**（位序从右往左，`dig5` 是最左）：

| 位 | 显示 |
|---|---|
| `dig5` | 当前选中的阈值编号 `1` / `2` / `3`；**这一位的小数点亮 = 纯二值图显示模式** |
| `dig4`~`dig2` | 选中阈值的十进制值（`000`~`255`） |
| `dig1`~`dig0` | 目标边界框宽度 ÷ 10；**没检测到目标时这两位熄灭** |

例：`0 1 0 3 2 7 1 9` → 阈值编号 3、阈值 010、目标宽 199 像素。

### 7. 颜色判据与可调参数

RGB565 先展成 8bit：`r8={R5,R5[4:2]}`、`g8={G6,G6[5:4]}`、`b8={B5,B5[4:2]}`

| 判据 | 条件 |
|---|---|
| 绿 | `(g8 >= TH_G) && (g8-r8 >= TH_G-R) && (g8-b8 >= TH_G-B)` |

三个判断式用的都是**带符号差值**，所以「白」「灰」（`G-R ≈ 0`）不会被误判成绿。
这个形式直接借自 dart 工程的 `Threshold.v`（那边是 10bit 影像，默认 `400 / 130 / 130`），
折算到 8bit 就是本工程的默认 `100 / 32 / 32`。

参数都在 `armor_vision.v` 的 parameter（改完重新综合即可）：

| 参数 | 默认 | 调整建议 |
|---|---|---|
| `TH_G_DEF` | 100 | 绿色亮度下限。**灯亮但检测不到**先调它（dart 的 400/4） |
| `TH_GR_DEF` | 32 | `G-R` 差值下限。受环境光/白平衡影响最大（dart 的 130/4） |
| `TH_GB_DEF` | 32 | `G-B` 差值下限 |
| `TH_MIN` | 24 | 投影阈值：一列/一行的最少亮点数。**圆没被框住先调这个**（0~480） |
| `MIN_SIZE` | 24 | 目标最小边长（宽、高都要 ≥ 它），挡小碎点 |
| `MORPH_N` | 9 | 形态学窗口（dart 用 9）。噪点多→9；想省资源→5 或 3（延迟行数跟着减半） |
| `RING_T` | 2 | 圆环半宽（像素） |
| `CROSS_L` | 12 | 中心十字臂长（像素） |
| `CLK_FREQ` | 25000000 | 只用于按键消抖时间（4.3" 800×480 的 `lcd_clk` = 25MHz） |

### 8. 资源使用（Vivado 2020.2，`armor_vision` out-of-context 综合）

| 模块 | LUT | 其中 LUTRAM | FF | DSP |
|---|---|---|---|---|
| `video_delay`（8 行 × 800 × 16bit） | 1999 | 1664 | 128 | 0 |
| `proj_bond`（两个直方图） | 613 | 210 | 177 | 0 |
| `morph_nxn` ×2 | 181 + 178 | 208 | 144 | 0 |
| `vision_cfg`（四颗按键消抖） | 158 | 0 | 119 | 0 |
| `overlay_box`（圆环两个平方 + 距离） | 55 | 0 | 0 | 4 |
| `color_seg` | 18 | 0 | 0 | 0 |
| `seg_display` | 29 | 0 | 19 | 0 |
| 顶层与显示合成 | 44 | 0 | 200 | 0 |
| **合计** | **3275（15.8%）** | 2082 | **787（1.9%）** | **4（4.4%）** |

Block RAM 0。原 39 例程（DDR3 MIG + FIFO + 相机 + LCD）的资源仍然充裕。
完整报告：`doc/synth_utilization_vision.rpt`、`doc/synth_utilization_hier.rpt`。

> **踩过的坑（很重要）**：一开始把行缓冲写成 `reg [WW-1:0] buf [0:NL-1][0:WIDTH-1]`，
> 读取放在 `always @(*)`、写入放在另一个时序区块，Vivado **不会**把它推断成 LUTRAM，
> 而是退化成「触发器 + 800 选 1 大 mux」——实测整个管线炸到
> **LUT 15747（75.7%）、FF 21684（52.1%）**，加进原工程一定塞不下。
> 改成 `line_buffer.v`（**同步写 + `assign dout = mem[raddr]` 连续赋值读**这个标准模板）
> 之后降到 **LUT 3168（15.2%）、FF 805（1.9%）**。
> 若之后要再加行缓冲/存储器，一律走 `line_buffer` 这个模板
> （`proj_bond.v` 里那两个直方图也是这样推出来的，实测 LUTRAM = 210）。

### 9. 常见问题 / 调试

| 症状 | 处理 |
|---|---|
| 完全没有标记、`led[3]` 一直闪 | ① 按 `key[3]` 切纯二值图，用 `key[0]`+`key[1]`/`key[2]` 把绿色调干净 ② 看数码管上 `TH_MIN` 是否太高 ③ 圆太小 → `MIN_SIZE` / `TH_MIN` 调小 |
| 二值图里绿圆是**白色一片** | 相机自动曝光把灯打爆成白色了（饱和后 `G-R ≈ 0` 判不出颜色）→ 降低环境光，或关掉 AEC/AWB 改固定曝光（见下条） |
| 一转屏幕角度就整个识别不到 | LCD 有光泽，房间灯按镜面反射射进镜头会**触发 OV5640 的自动曝光/自动白平衡**，把整幅画面的亮度/色彩一起拉走，固定阈值随即全线失守。建议把 `i2c_ov5640_rgb565_cfg.v` 的 `0x3503` 设成手动、给死曝光与增益（`0x3406` 同理关 AWB）——dart 工程就是固定曝光 + 固定增益；物理上可贴防眩光膜或加偏振片 |
| 标记画歪 / 圆环不贴边 | ① 圆环半径由 `(宽+高)/4` 得来，边界框不准就会歪 → 先看二值图 ② `RING_T` / `CROSS_L` 调粗细 |
| 框跳来跳去 | ① 阈值卡在边缘 → 调 `TH_MIN` ② 背景有同色大面积 → 提高 `TH_G` ③ `MIN_SIZE` 调大一点 |
| 画面最上面 16 行有残影 | 行缓冲在帧首还没填满，检测端已用 `Y_GUARD` 排除；残影只是显示 |
| 数码管显示倒过来 | 板子位选顺序与本模块假设相反 → 把 `seg_display.v` 的 `SEG_REV` 参数设成 `1` |
| 资源不够 / 时序不过 | `MORPH_N` 改 5 或 3 |

### 10. 已知限制与后续方向

- **只输出一个目标**：取最宽列 run / 最长行 run，画面里同时出现多个绿块时只会框住最大的那一个
  → 需要多目标就要上完整 CCL（可参考 dart 工程的 `FindBond.v`：256 标签 + BRAM 存每块结构 + 帧末选面积最大的）
- **没有距离/大小解算**：目前只给圆心与边界框
  → 要报靶需要相机内参 + 靶标实际直径
- **颜色分割对光照敏感**：可加自适应阈值（例如用整帧直方图峰值动态定 `TH_MIN`）；
  也可以把判据改成「相对饱和度」（`(max-min)*4 >= max`）让整体变暗/变淡时依然成立
- 其他可延伸：圆心经 UART 送给上位机 / 加 ILA 观察两个直方图峰值 / 圆心坐标接 OLED
- 对应《RM飞镖FPGA视觉方案》文件的阶段 1~6 皆已完成（验证对照表见 `doc/vision_pipeline.md`）

### 11. 还原

改成绿色靶标**之前**的文件在 `_backup_before_green/`：

```powershell
Copy-Item _backup_before_green\rtl\*.v                      rtl\        -Force
Copy-Item _backup_before_green\prj\ov5640_lcd.srcs\constrs_1\new\pin.xdc prj\ov5640_lcd.srcs\constrs_1\new\ -Force
Copy-Item _backup_before_green\sim\tb_armor_vision.v        sim\        -Force
Copy-Item _backup_before_green\README.md                    .\          -Force
Copy-Item _backup_before_green\vision_pipeline.md           doc\        -Force
```

未加入视觉管线**之前**的原始 39 例程文件在 `_backup_before_vision/`：

```powershell
Copy-Item _backup_before_vision\ov5640_lcd.v.bak   rtl\ov5640_lcd.v -Force
Copy-Item _backup_before_vision\pin.xdc.bak        prj\ov5640_lcd.srcs\constrs_1\new\pin.xdc -Force
Copy-Item _backup_before_vision\ov5640_lcd.xpr.bak prj\ov5640_lcd.xpr -Force
```

若之后又从官方例程复制一份干净的 39 工程，可执行 `python tools/patch_project.py` 接回视觉管线，
再执行 `python tools/patch_green.py` 接上绿色靶标这一版。

### 12. 开发工具（`tools/`）

| 脚本 | 用途 |
|---|---|
| `run_vision_sim.bat`（在 `sim/`） | 一键跑 xsim 自检（编译 → 精化 → 仿真） |
| `synth_check_vision.tcl` | 对 `armor_vision` 做 out-of-context 综合，检查 LUTRAM 推断与资源 |
| `patch_project.py` | 把视觉管线接进官方 39 例程（已应用过，重复执行会自动跳过） |
| `patch_green.py` | 从「红蓝灯条」版升级到「绿色圆靶标」版（改 `ov5640_lcd.v` 埠/例化、`pin.xdc` 注释与数码管引脚、`xpr` 注册新文件；字节级安全，可重复执行） |
| `to_gbk.py` | 新增文件的中文注释 UTF-8 → GBK（与工程其他文件一致） |
| `to_simplified_gbk.py` | 把代码档的中文由繁体转成简体、并统一存成 GBK（幂等，可重复执行；`--apply` 才写入） |
| `check_project_paths.py` | 检查 `.xpr` 引用的文件是否都在（搬移/复制工程后很好用） |

### 13. 编码注意（**很重要**）

- `rtl/*.v`、`prj/**/*.xdc` 等 Vivado 文件是 **GBK** 编码（Vivado 在中文 Windows 下用 ANSI）。
- `doc/*.md`、`tools/*.py` 是 **UTF-8**。
- 用 VS Code 编辑 `.v` 时请确认右下角编码是 `GBK`（VS Code 通常会自动检测）；
  若存成 UTF-8，Vivado 内置编辑器看到的中文注释会变乱码。
- 要**批量改 GBK 文件**不要用普通编辑器保存，请照 `tools/patch_green.py` 的做法
  用 Python（GBK 解码 → 改 → GBK 编码，写回前往返比对）或纯 ASCII 字节级替换。

### 14. 授权与致谢

- 本项目以 **MIT License** 发布（见 [LICENSE](LICENSE)）。
- 基础工程来自正点原子（ALIENTEK）官方 FPGA 例程 **39_ov5640_lcd**（OV5640 + DDR3 + RGB LCD）。
- 绿色判据与「形态学 + 找最大色块」的思路参考 2026 飞镖开源工程 `dart2026_-open-source`
  （`dart_-fpga/fpga/ip/isp/Threshold_ip/src/Threshold.v`、`FindBond_ip/src/FindBond.v`）。

---

## 繁體中文說明

> 為助力兩岸四地青年共圓工程夢，本專案特提供繁體中文版本 README。
> 以官方 **39_ov5640_lcd** 例程為起點，在「DDR3 讀出」與「LCD 寫入」之間插入一條純 Verilog 視覺管線：
> 綠色分割 → 形態學閉運算 → **雙投影找綠塊** → 紅色圓環 + 中心十字，並把三個門檻顯示在板載 6 位數碼管。
> 深入設計說明（時序關係、雙投影原理、Vivado LUTRAM 推斷踩坑）請看 **[doc/vision_pipeline.md](doc/vision_pipeline.md)**。

### 1. 功能

| 功能 | 說明 |
|---|---|
| 綠色分割 | RGB565 → 1bit 二值圖，判據 `G>=TH_G && G-R>=TH_G-R && G-B>=TH_G-B`（借自 dart 的 `Threshold.v`） |
| 形態學去噪 | 9×9 膨脹 → 9×9 腐蝕 = **閉運算**，填補綠圓內部小洞、去掉碎點 |
| 目標定位 | **雙投影**：X 直方圖找最寬的連續亮欄 run → 左右邊界；Y 直方圖找最長的連續亮列 run → 上下邊界 |
| 圓形狀校驗 | 寬高都 ≥ `MIN_SIZE`、寬高比在 2:1 內、峰欄高度 ≥ 3/4 高 —— 擋掉反光塊 / 雜色塊 |
| 標記輸出 | **紅色圓環**（半徑 = (寬+高)/4，環寬 ±`RING_T`）+ 中心十字；另可切純二值圖模式方便調門檻 |
| 數碼管 | 6 位共陽數碼管即時顯示「門檻編號 + 選中門檻(000~255) + 目標寬度/10」 |
| 狀態指示 | 4 顆 LED：目前在調哪個門檻（3 顆）、偵測到目標（常亮 / 未偵測到時 1.5Hz 閃） |

### 2. 硬體與環境

| 項目 | 內容 |
|---|---|
| FPGA | 正點原子達芬奇 **XC7A35TFGG484-2**（20,800 LUT / 41,600 FF / 1,800Kb BRAM / 90 DSP） |
| 相機 | OV5640，RGB565，800×480（DVP 介面） |
| 顯示 | 4.3 吋 800×480 RGB LCD（`lcd_id` = `0x7084` / `0x4384`，像素時鐘 25 MHz） |
| 數碼管 | 板載 6 位共陽數碼管：`seg_sel[5:0]` 位選（低電平選通）、`seg_led[7:0] = {dp,g,f,e,d,c,b,a}`（低電平點亮） |
| 開發工具 | Vivado 2020.2（模擬器 xsim） |
| 按鍵腳位 | `key[3:0]` = T1 / U1 / W2 / T3（**低電平有效**） |
| LED 腳位 | `led[3:0]` = R2 / R3 / V2 / Y2（**低電平點亮**） |
| 數碼管腳位 | `seg_sel[5:0]` = J15 / H17 / H13 / G17 / H18 / G18；`seg_led[7:0]` = H15 / G16 / L13 / G15 / K13 / G13 / H14 / J14 |
| 復位 | `sys_rst_n` = U2 |

### 3. 目錄結構

```
FPGA4dart/
├── rtl/                 # Verilog 原始碼（GBK 編碼）
│   ├── armor_vision.v   #   視覺管線頂層
│   ├── color_seg.v      #   綠色分割（純組合邏輯）
│   ├── morph_nxn.v      #   N×N 膨脹 / 腐蝕
│   ├── line_buffer.v    #   單行緩衝（LUTRAM 標準模板）
│   ├── video_delay.v    #   像素串流延遲（原圖對齊）
│   ├── proj_bond.v      #   雙投影找綠塊 + 邊界框 / 圓心
│   ├── overlay_box.v    #   紅色圓環 + 中心十字
│   ├── seg_display.v    #   6 位數碼管驅動
│   ├── vision_cfg.v     #   按鍵 → 三個門檻 / 顯示模式
│   ├── key_debounce.v   #   按鍵同步 + 消抖 + 按下沿
│   └── (官方 39 例程原有的 13 個檔案)
├── sim/                 # tb_armor_vision.v + run_vision_sim.bat（一鍵 xsim）
├── prj/                 # ov5640_lcd.xpr + ov5640_lcd.srcs（IP 的 .xci 都在）
├── doc/                 # vision_pipeline.md、方塊圖 vsdx、合成資源報告
├── tools/               # 開發腳本（見第 12 節）
├── _backup_before_vision/   # 未加入視覺前的原始 39 例程檔案（還原用）
└── _backup_before_green/    # 改成綠色靶標前的檔案（還原用）
```

### 4. 系統架構

```mermaid
flowchart TD
    IN["DDR3 讀出<br/>rddata / rdata_req / rd_vsync"] --> ALIGN["輸入對齊<br/>（打一拍）"]
    ALIGN --> SEG["color_seg<br/>綠色分割"]
    SEG --> DIL["morph_nxn 9×9<br/>膨脹"]
    DIL --> ERO["morph_nxn 9×9<br/>腐蝕（= 閉運算）"]
    ERO --> MASK["mask_d 二值圖"]
    ALIGN --> DLY["video_delay<br/>延遲 8 行 + 8 像素"]
    MASK --> PROJ["proj_bond<br/>雙投影<br/>最寬欄 run / 最長列 run"]
    MASK --> MIX["顯示合成"]
    DLY --> MIX
    PROJ --> OVL["overlay_box<br/>紅色圓環 + 中心十字"]
    PROJ --> SEGD["seg_display<br/>6 位數碼管"]
    OVL --> MIX
    MIX --> LCD["4.3 吋 RGB LCD 800×480"]
```

**三個關鍵設計決定**

1. **用雙投影取代連通域標記（CCL）**：靶標只有**一個**大綠圓，X / Y 兩個 1D 直方圖就能把它框住。
   資源只要 `800×10bit + 480×10bit` 的 LUTRAM，沒有等價類合併、label 回收這些容易出錯的邏輯。
2. **形態學窗口是「右下角對齊」**：二值圖在螢幕上會整體往右下偏移 `N-1 = 8` 像素，
   所以用 `video_delay` 把**原圖也延遲 8 行 + 8 像素**，兩者在螢幕上完全對齊。
3. **環與十字畫在同一像素串流座標上**：`proj_bond` 統計出來的座標就是螢幕座標，`overlay_box` 直接比對。

**時間關係**：直方圖在有效顯示行累積；幀末先掃 X（801 拍）再掃 Y（481 拍），共約 1283 拍；
垂直消隱有約 47000 拍，非常寬裕。X 與 Y 在**同一幀**算完，所以**框不再慢一幀**。

### 5. 模擬驗證

```powershell
cd sim
.\run_vision_sim.bat
# 等同於： xvlog <設計檔...> ; xelab -debug typical tb_armor_vision -s tb_vision ; xsim tb_vision -runall
```

測試台造出與 `lcd_driver`（800×480 面板）**完全相同**的時序，影像為
**一個綠色實心圓**（圓心 (400,240)、半徑 100、`RGB565 = 0x750E` → `r8=118 g8=162 b8=118`），並驗證 33 項：

| 階段 | 檢查 | 期望 | 說明 |
|---|---|---|---|
| 1 | `bond_l` / `bond_r` | 309 / 507 | 圓心 + 形態學偏移 8 後是 (408,248)、半徑 100 |
| 1 | `bond_t` / `bond_b` | 149 / 347 | 上下同理 |
| 1 | `center_x` / `center_y` | 408 / 248 | 圓心 |
| 1 | `bond_w` | 199 | 投影門檻 `TH_MIN=24` 讓左右各內縮 1 像素 |
| 1 | `inside_green` | `0x750E` | 圓內：命中 → 保持原色 |
| 1 | `bg_dim` | `0x4208` | 圓外背景：未命中 → 亮度減半 |
| 1 | `ring_red` / `center_red` | `0xF800` | 圓環上 (507,248) 與圓心都是紅色標記 |
| 2 | `sel` | 1 | 按 `key[0]` 一次 → 選中項切到 `TH_G-R` |
| 3 | `th_gr` / `bond_valid` | 48 / 0 | 按 `key[1]` 兩次 → 48 > 44 → **目標遺失** |
| 4 | `th_gr` / `bond_valid` | 32 / 1 | 按 `key[2]` 兩次 → 門檻回來 → **恢復偵測** |
| 5 | `sel` | 2 | 再按 `key[0]` 一次 → 選中項切到 `TH_G-B` |
| 6 | `disp_bin` / `bin_white` | 1 / `0xFFFF` | 按 `key[3]` → 純二值模式，圓內顯示白色 |

實測輸出：`==== ALL CHECKS PASSED ====`（33 項）。

### 6. 按鍵 / LED / 數碼管

| 按鍵 | 腳位 | 功能 |
|---|---|---|
| `key[0]` | T1 | 循環選擇要調的門檻：`TH_G` → `TH_G-R` → `TH_G-B` → `TH_G` |
| `key[1]` | U1 | 當前選中的門檻 +8（上限 255） |
| `key[2]` | W2 | 當前選中的門檻 −8（下限 0） |
| `key[3]` | T3 | 顯示模式切換（0 = 原圖變暗+標記；1 = 純二值圖） |

| LED | 腳位 | 意義 |
|---|---|---|
| `led[0]` | R2 | 目前在調 `TH_G` |
| `led[1]` | R3 | 目前在調 `TH_G-R` |
| `led[2]` | V2 | 目前在調 `TH_G-B` |
| `led[3]` | Y2 | 偵測到目標常亮；未偵測到時 1.5 Hz 閃爍 |

**6 位數碼管**（位序從右往左，`dig5` 是最左）：

| 位 | 顯示 |
|---|---|
| `dig5` | 門檻編號 `1` / `2` / `3`；**小數點亮 = 純二值圖顯示模式** |
| `dig4`~`dig2` | 選中門檻的十進位值（`000`~`255`） |
| `dig1`~`dig0` | 目標邊界框寬度 ÷ 10；**沒偵測到目標時這兩位熄滅** |

### 7. 顏色判據與可調參數

RGB565 先展成 8bit：`r8={R5,R5[4:2]}`、`g8={G6,G6[5:4]}`、`b8={B5,B5[4:2]}`

| 判據 | 條件 |
|---|---|
| 綠 | `(g8 >= TH_G) && (g8-r8 >= TH_G-R) && (g8-b8 >= TH_G-B)` |

三個判斷式用的都是**帶符號差值**，所以「白」「灰」不會被誤判成綠。
這個形式直接借自 dart 工程的 `Threshold.v`（10bit 預設 `400 / 130 / 130`），折算到 8bit 就是 `100 / 32 / 32`。

| 參數 | 預設 | 調整建議 |
|---|---|---|
| `TH_G_DEF` | 100 | 綠色亮度下限。**燈亮但偵測不到**先調它 |
| `TH_GR_DEF` | 32 | `G-R` 差值下限。受環境光/白平衡影響最大 |
| `TH_GB_DEF` | 32 | `G-B` 差值下限 |
| `TH_MIN` | 24 | 投影門檻：一欄/一列的最少亮點數。**圓沒被框住先調這個** |
| `MIN_SIZE` | 24 | 目標最小邊長，擋小碎點 |
| `MORPH_N` | 9 | 形態學窗口；想省資源 → 5 或 3 |
| `RING_T` | 2 | 圓環半寬（像素） |
| `CROSS_L` | 12 | 中心十字臂長（像素） |
| `CLK_FREQ` | 25000000 | 只用於按鍵消抖時間 |

### 8. 資源使用

| 模組 | LUT | 其中 LUTRAM | FF | DSP |
|---|---|---|---|---|
| `video_delay` | 1999 | 1664 | 128 | 0 |
| `proj_bond` | 613 | 210 | 177 | 0 |
| `morph_nxn` ×2 | 181 + 178 | 208 | 144 | 0 |
| `vision_cfg` | 158 | 0 | 119 | 0 |
| `overlay_box` | 55 | 0 | 0 | 4 |
| `color_seg` | 18 | 0 | 0 | 0 |
| `seg_display` | 29 | 0 | 19 | 0 |
| 頂層與顯示合成 | 44 | 0 | 200 | 0 |
| **合計** | **3275（15.8%）** | 2082 | **787（1.9%）** | **4（4.4%）** |

Block RAM 0。原 39 例程的資源仍然充裕。完整報告：`doc/synth_utilization_vision.rpt`。

### 9. 常見問題 / 除錯

| 症狀 | 處理 |
|---|---|
| 完全沒有標記、`led[3]` 一直閃 | ① 按 `key[3]` 切純二值圖，把綠色調乾淨 ② `TH_MIN` 是否太高 ③ 圓太小 → `MIN_SIZE` / `TH_MIN` 調小 |
| 二值圖裡綠圓是**白色一片** | 相機自動曝光把燈打爆成白色了（飽和後 `G-R ≈ 0`）→ 降低環境光，或關掉 AEC/AWB 改固定曝光 |
| 一轉螢幕角度就整個識別不到 | LCD 有光澤，房間燈按鏡面反射射進鏡頭會**觸發 OV5640 的自動曝光/自動白平衡**，把整幅畫面的亮度/色彩一起拉走，固定門檻隨即全線失守。建議把 `0x3503` 設成手動、給死曝光與增益（`0x3406` 同理關 AWB）——dart 工程就是固定曝光 + 固定增益；物理上可貼防眩光膜或加偏振片 |
| 標記畫歪 / 圓環不貼邊 | 圓環半徑由 `(寬+高)/4` 得來，先看二值圖是否乾淨 |
| 框跳來跳去 | 調 `TH_MIN` / 提高 `TH_G` / `MIN_SIZE` 調大 |
| 畫面最上面 16 行有殘影 | 行緩衝在幀首還沒填滿，檢測端已用 `Y_GUARD` 排除 |
| 數碼管顯示倒過來 | 把 `seg_display.v` 的 `SEG_REV` 設成 `1` |
| 資源不夠 / 時序不過 | `MORPH_N` 改 5 或 3 |

### 10. 已知限制與後續方向

- **只輸出一個目標**：需要多目標就要上完整 CCL（可參考 dart 工程的 `FindBond.v`）
- **沒有距離/大小解算**：目前只給圓心與邊界框
- **顏色分割對光照敏感**：可加自適應門檻，或把判據改成「相對飽和度」讓整體變暗/變淡時依然成立
- 其他可延伸：圓心經 UART 送給上位機 / 加 ILA 觀察兩個直方圖峰值

### 11. 還原

改成綠色靶標**之前**的檔案在 `_backup_before_green/`；
未加入視覺管線**之前**的原始 39 例程檔案在 `_backup_before_vision/`（指令見簡體中文版第 11 節）。

### 12. 開發工具（`tools/`）

| 腳本 | 用途 |
|---|---|
| `run_vision_sim.bat`（在 `sim/`） | 一鍵跑 xsim 自檢 |
| `synth_check_vision.tcl` | 對 `armor_vision` 做 out-of-context 合成，檢查 LUTRAM 推斷與資源 |
| `patch_project.py` | 把視覺管線接進官方 39 例程（已套用過） |
| `patch_green.py` | 升級成「綠色圓靶標」版（改 `ov5640_lcd.v`、`pin.xdc`、`xpr`；可重複執行） |
| `to_gbk.py` | 新增檔案的中文註解 UTF-8 → GBK |
| `to_simplified_gbk.py` | 中文由繁體轉簡體並統一存成 GBK |
| `check_project_paths.py` | 檢查 `.xpr` 引用的檔案是否都在 |

### 13. 編碼注意（**很重要**）

- `rtl/*.v`、`prj/**/*.xdc` 等 Vivado 檔案是 **GBK** 編碼（Vivado 在中文 Windows 下用 ANSI）。
- `doc/*.md`、`tools/*.py` 是 **UTF-8**。
- 用 VS Code 編輯 `.v` 時請確認右下角編碼是 `GBK`；若存成 UTF-8，Vivado 內建編輯器看到的中文註解會變亂碼。
- 要**批次改 GBK 檔案**請照 `tools/patch_green.py` 的做法用 Python 處理。

### 14. 授權與致謝

- 本專案以 **MIT License** 發布（見 [LICENSE](LICENSE)）。
- 基礎工程來自正點原子（ALIENTEK）官方 FPGA 例程 **39_ov5640_lcd**。
- 綠色判據與「形態學 + 找最大色塊」的思路參考 2026 飛鏢開源工程 `dart2026_-open-source`。
