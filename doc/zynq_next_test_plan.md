# Zynq 下一轮测试计划（2026-11-15）

> 依据：最近一次上板结果是 11/13 夜（`doc/zynq_board_bringup.md` §20，LCD 仍黑屏）；
> 11/14 20:38 重新出了 bitstream（`prj/zynq_vision/zynq_vision.runs/impl_1/system2_wrapper.bit`），
> 里面有两个未上板验证的改动：① `clk_wiz_lcd` 用 MMCM 出 50 MHz 取代 fabric 分频；
> ② `axi_frame_buf` 读页在 LCD 帧首锁存（`rd_page_r <= wr_page_done`）。
> 提交 `b526b16` 的动机写的是"屏幕闪烁 / OSD 十字乱跳"，说明当时画面已经出来了——
> **文档落后于代码，本轮第一件事是把现状重新测出来。**

范围：只验 PL 侧（相机 → DDR → 视觉 → LCD）+ PS 寄存器通路。
**不做**：电机/舵机闭环、无线图传（见 §6）。

---

## 0. 前置（1 分钟，别跳）

- [ ] 烧的确实是 11/14 那个 bit：工作区干净（`git status` 无输出），bit 时间 11/14 20:38 晚于源文件
      20:28，所以它就是当前 RTL 的产物。
- [ ] 串口控制台能进（板载 CH340，MIO14/15）。
- [ ] 记下 `devmem 0x43C00000` = `0x56495331`（"VIS1"）。不是这个值 → 先别往下测，PL 里的东西不对。

---

## 1. P0：现状判定（5 分钟）

```bash
devmem 0x43C00000                  # ID = 0x56495331
devmem 0x10000000; devmem 0x10100000   # 两页帧缓存
for i in 1 2 3; do devmem 0x43C00014; sleep 1; done   # FRAME_CNT
devmem 0x43C00018                  # FPS
devmem 0x43C0001C                  # FLAGS
devmem 0x43C00020; devmem 0x43C0002C # CX / AY
```

看板载 **G14 LED**（`rtl/ov5640_lcd_zynq.v:244`，`lcd_clk` 的 2^24 分频，约 1.5 Hz）。

| 现象 | 结论 | 下一步 |
|---|---|---|
| LED 不闪 | `lcd_clk` 没跑 / 复位没放开 | 查 `clk_wiz_lcd` 的 locked、`sys_rst_n`、`startup_delay_done`；**先别查画面** |
| LED 闪，FRAME_CNT = 0 且不涨 | 显示域没产生 vsync（`frame_tick` 来自 LCD `out_vsync`） | 查 `lcd_rgb_top` 的 `sys_init_done` / `lcd_driver.rst_n`、`picture_size` 是否 800×480 |
| FRAME_CNT 在涨 | 显示时序在跑 | 看屏幕：黑 / 抖 / 正常，进 P1 |
| 帧缓存某页全 `0xFFFFFFFF` | 写通道有问题 | 回到相机采集（11/13 已是好的，先怀疑这版 BD 改动） |

---

## 2. P1：显示验收（0.5 小时）

通过标准（全部满足）：
1. FRAME_CNT 每秒增量稳定在几十帧（`devmem` 两次读数差 / 间隔）；
2. 屏幕有相机画面，**无横纹、无撕裂**（11/14 两个修复就是冲这个去的）；
3. 帧缓存两页都是真实像素（比如 `0x0101FDF2` 这类），不是纯 `FF`/纯 `00`。

（OSD 触发圈/十字的稳定性放到 P2：`OSD_EN` 默认是 0，P1 阶段屏幕上本来就没有它。）

失败分叉：
- **仍黑屏但 FRAME_CNT 在涨** → 数据/背光/时序问题，需要波形：BD 里加 `system_ila`
  （挂 `lcd_clk / lcd_hs / lcd_vs / lcd_de / rd_vsync` + `rfifo` 读口）。加 ILA 要改 BD → 人重导
  XSA → 重跑 impl（约 20–40 min），先确认没有更便宜的证据再动。
- **画面抖/闪** → 量 `lcd_pclk` 应为 25.0 MHz（clk_wiz 50 MHz 再经 `clk_div` 二分）。
  偏离就先查 `clk_wiz_lcd` 的输出频率配置，而不是改 `lcd_driver` 时序参数。
- **撕裂** → 说明读页锁存没生效或读写页相位反了，回头看 `axi_frame_buf.v` 的
  `rd_page_r` / `wr_page_done`。

---

## 3. P2：UART 独立通道 + 合成靶标自检（1 小时，不用相机也不用靶）

这一条是本轮性价比最高的：**不依赖任何外部目标、不依赖电机**，就能证明
"视觉核 → OSD → UART 上报"整条链路是活的。

### 3.1 先证明 UART 本来就没坏

11/13 记录的"3507 字节 / 20 秒乱码"其实已经能反推波特率：34 字节一帧、`TX_DIV=8`，
175 B/s ÷ 34 B ≈ 5.1 帧/s × 8 ≈ 41 fps —— 与 115200 8N1 自洽。
即：**协议是二进制的，不是波特率错**（帧格式见 `tools/uart_parse.py` 头部注释，v3 34 字节）。

先离线自检解析器（不需要板子、不需要串口，一条命令应有下面这行输出）：

```powershell
.\.venv\Scripts\python.exe tools\uart_parse.py --hex "A5 5A 81 01 90 00 F0 01 90 00 C8 78 F3 C9 01 00 10 00 00 01 A0 00 C8 00 C8 00 0A 01 A0 00 C8 05 D9 1A"
# [OK] valid=True ... 圆心=(400,240) 瞄准=(400,200) w=120 area~31104 ... seq=5
```

再上串口：

```powershell
.\.venv\Scripts\python.exe tools\uart_parse.py --list   # 先认口，别猜 COM 号
.\.venv\Scripts\python.exe tools\uart_parse.py COM7     # 实时解析
```

前置：`pyserial` 还没装（本机 `.venv` 里 `import serial` 失败；这个会话的沙箱里 pip 写临时文件被拒，
装不上），**在你自己的终端里**跑一次 `python -m pip install pyserial` 即可。
`--hex` 离线模式不需要它。

判据：10 帧内 `0xA5 0x5A` 帧头全中、`seq` 逐帧 +1、CRC16 全过。
（顺便证明 `lcd_clk` 是准的 25 MHz——波特率直接吃这个时钟。）

### 3.2 UART 收 + 合成靶标

先单独验证 **UART 收**（这一步比 SYN 更简单，别跳）：`CTRL.b3` 一置，LCD 立刻切成黑底白块的二值图。

```powershell
.\.venv\Scripts\python.exe tools\uart_parse.py COM7 --set 0x07 0x08   # 二值显示 ON
.\.venv\Scripts\python.exe tools\uart_parse.py COM7 --set 0x07 0x00   # 恢复彩色
```

**看不到二值图 = UART 收不通**（F19 接错 / 模块是 5 V / 校验字节不对），先修这个再看别的。

注意：**当前 bitstream 的 OSD 是关的**（`armor_vision.v:93` `OSD_EN = 1'b0`，顶层没覆盖），
只靠 `SYN_EN` 看不到圆环——必须同时置 `CTRL.b4`。

```powershell
.\.venv\Scripts\python.exe tools\uart_parse.py COM7 --set 0x07 0x18   # b4 OSD + b3 二值（可选）
.\.venv\Scripts\python.exe tools\uart_parse.py COM7 --set 0x0F 0x01   # SYN_EN：用合成靶标替代相机
.\.venv\Scripts\python.exe tools\uart_parse.py COM7                   # 看 cx 是否在动
.\.venv\Scripts\python.exe tools\uart_parse.py COM7 --set 0x0F 0x00   # 关掉
```

判据：
- LCD 上出现绿色圆（合成靶标默认半径 60 px、速度 5 px/帧往返，`rtl/syn_target.v`），
  打开 b4 后应叠上跟随它的圆环/十字；
- UART 的 `cx` 单调往返、`flags.b0=1`；
- 关掉后回到相机画面。

**这一条同时验证了三件事**：UART 收（`0xAA addr data chk`）→ `reg_file` → 视觉参数生效；
OSD 叠印在 LCD 上；结果帧的坐标与画面一致。它比"摆一个绿灯"更能定位问题，建议先做它。

---

## 4. P3：PS ↔ PL 控制契约（半天，要改 RTL）

现状（已核实）：PS 只能写 `CTRL / IRQ_EN / SCRATCH` 三个寄存器
（`rtl/vision_regs_axi.v:15-28`、写通道 265-283）；阈值区 `0x08~0x3C` **没实现**；
`vision_top/irq` 在 BD 里**悬空没接 `IRQ_F2P`**。所以"PS 下发阈值""帧中断通知"目前都不成立。

建议做法（最省改动，且不制造第二套参数路径）：
- 在 AXI 里加 3 个寄存器：`PARAM_ADDR / PARAM_DATA / PARAM_WR`；
- PL 侧把 `PARAM_WR` 变成 `reg_file` 的一个写脉冲，复用现有 `0x00~0x12` 参数表
  （见附录 B），而不是另写一套视觉参数寄存器；
- 把 `vision_top/irq` 接到 `IRQ_F2P[0]`，BD 里补 `xlconcat`。

验收：
1. `devmem 0x43C00010 32 0xDEADBEEF; devmem 0x43C00010` → 原值读回；
2. 用 AXI 把 `TH_G` 写成 0 / 255 两个极端值 → LCD 二值图（b3 打开）应肉眼可见地全变；
3. `cat /proc/interrupts` 的中断计数与 `FRAME_CNT` 差值 ≤ 1（观察 1 小时不漂）。

> 这步完成之前，不要动 Linux 驱动 / `dart_-application` 对接——接口还没定型。

---

## 5. P4：真实靶精度（0.5 天，无电机）

用绿灯/绿圆靶（就是之前那套），固定不动，依次放在画面 9 个位置：

| 检查 | 判据 |
|---|---|
| `CX/CY` 与画面外框中心 | 误差 ≤ 2 px |
| `AX/AY` 与几何瞄准点 | 与画面上 OSD 十字重合 |
| UART `fx/fy` 与 `AX/AY` | 同一帧内一致 |
| `BW/AREA` 随距离变化 | 靶远→BW 变小、`DIST_CM` 变大，单调 |
| 手推靶移动 | `VX/VY` 符号正确、幅值随速度变化 |

记录方式：每测一个位置，存一张照片 + 一段 `devmem` dump + 一屏 UART 解析输出。

---

## 6. 本轮不做的两件事（以及什么时候才做）

**电机/舵机**：当前 BD 没有 `pwm_6ch`，XDC 也没有 PWM 脚。舵机属于产品化 E 线
（`ZYNQ_TEST_PLAN.md:201-202`，333 Hz、500–2500 µs、脉宽误差 < ±10 µs）。
触发条件：P4 通过、且要演示"视觉→云台"闭环时，再加 IP + 引脚 + 驱动。

**天线（小辣椒）/无线**：现在整条验收链路全是有线的（LCD 排线 + USB-TTL + SD 卡），
用不到天线；而且设备树里 `gem0` 还是 disabled（`eth0` 不存在），网络本身还不成立。
触发条件：要做图传/遥测（P6）时，先启用 `&gem0` 打通网口，再按实际无线方案
（WiFi / 5.8G 模拟图传 / 网口有线）决定接哪根天线、挂在哪一级。

---

## 附录 A：AXI 寄存器（`0x43C0_0000`，`rtl/vision_regs_axi.v`）

| 偏移 | 名称 | 属性 | 说明 |
|---|---|---|---|
| 0x00 | ID | RO | `0x56495331` |
| 0x04 | CTRL | RW | b0 SW_IRQ（写 1 自清） |
| 0x08 | IRQ_EN | RW | b0 帧末中断使能 |
| 0x0C | IRQ_STATUS | W1C | b0 frame_done |
| 0x10 | SCRATCH | RW | 写读回，验证 AXI 通路 |
| 0x14 | FRAME_CNT | RO | 复位后帧数（LCD vsync） |
| 0x18 | FPS | RO | ~1 s 窗口帧率 |
| 0x1C | FLAGS | RO | [0]valid [1]dist_ok [2]pred_ok [3]adapt_ok |
| 0x20/24/28/2C | CX/CY/AX/AY | RO | 外框中心 / 瞄准点 |
| 0x30/34/38/3C | BW/AREA/DIST/DROP | RO | 宽度 / 面积 / 距离 / 下坠 |
| 0x40/44/48/4C | VX/VY/PX/PY | RO | 速度 Q4 / 预测点 |

## 附录 B：UART 参数地址（`0xAA addr data (addr^data)`，`rtl/reg_file.v:107-125`）

| addr | 含义 | 默认 |
|---|---|---|
| 0x00/01/02 | TH_G / TH_G-R / TH_G-B | 100 / 32 / 32 |
| 0x03 | REL_SAT% | 20 |
| 0x04 | MIN_SIZE（面积门限低档） | 8 |
| 0x05 | AIM_H_Q8 | 116 |
| 0x06 | RING_T | 2 |
| 0x07 | CTRL：b0 自适应阈值 · b1 中值滤波 · b2 AEC · b3 二值显示 · b4 OSD · b5 速度预测 · b6 距离补偿 · b7 多帧累积 | 0 |
| 0x08/09/0A/0B/0C | GATE / PCT / LEAD_Q4 / DROP_SC / TACC | 96 / 15 / 64 / 255 / 2 |
| 0x0D/0E/0F | SYN_SPD / SYN_R / SYN_EN | 80 / 60 / 0 |
| 0x10/11/12 | ST_PAGE / LEAD_AUTO / FLAGS2(b0 强制跟踪器) | 0 / 1 / 0 |

## 附录 C：风险与前置

| 风险 | 影响 | 处置 |
|---|---|---|
| 无 ILA / VIO | 抓不到板内波形 | 需要时改 BD 加 `system_ila`，重跑 impl |
| 帧中断未接 | 只能轮询，看不到"帧到"事件 | P3 里接线 |
| 阈值 AXI 未实现 | PS 改不了阈值 | P3 里加 3 个寄存器 |
| `eth0` 未启用 | 无线/图传不成立 | P6 前先在 DT 打开 `&gem0` |
| 文档落后于代码 | 容易误判现状 | 每跑完一节，把实测数字补回 `doc/zynq_board_bringup.md` |
