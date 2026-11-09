# PL + PS 三条线：A（AXI 契约）/ B（Linux 环境）/ C（接口与资源）

> 目标工程：`C:\Users\DUANboyang\Desktop\FPGA4dart`（XC7Z020 挑战者底板）
> 目标产品：`C:\Users\DUANboyang\Desktop\dart2026_-open-source`（飞镖真机，XC7Z010 + PetaLinux 2020.2）
> 本文只回答三件事：**现在做什么、需要准备什么、哪些能并行**。
> 判据一律写成可观测的形式（`mrd` 读到的值、ISR 计数、示波器脉宽），不写"正常/OK"。

---

## 0. 三条线总览

| 线 | 目标 | 依赖 | 预计 | 产出 |
|---|---|---|---|---|
| **A** | 打通 PL↔PS 契约：PS 通过 AXI4-Lite 读视觉结果、收帧末中断 | 第 0 步（bit 能上板出图） | 1 周 | `rtl/vision_regs_axi.v`、BD 改造、XSA、裸机/驱动验证 |
| **B** | PetaLinux 2020.2 环境 + 基于新 XSA 的 Linux 工程 | 环境安装可先做；建工程要 A 的 XSA | 装 1~2 天，建 3~5 天 | `BOOT.BIN` + `image.ub`、串口登录、驱动 probe |
| **C** | 接口对齐与资源收口（**不阻塞任何人**） | 无 | 半天~1 天 | 寄存器/ioctl 映射表、xc7z010 OOC 综合报告、判据脚本 |

**并行原则**：A 和 C 今天就能同时开工；B 的"装环境"今天也能开工，只有"建工程"要等 A 出 XSA。

---

## 1. A 线：PL ↔ PS 契约（本轮主线）

### A.0 先确认现状（0.5 天，没通就别加逻辑）

1. 按 [zynq_bringup.md](zynq_bringup.md) 的顺序下载：`ps7_init` → `ps7_post_config` → `fpga -file ...bit`
   （顺序不能反：DDR 没初始化，HP0 帧缓存不通，画面是死的）。
2. 判据：LCD 出图；外接 USB-TTL（**PL UART 在 F19/F20 排针**，板载 USB 是 PS 的 MIO14/15）115200 能收到 v3 帧。
3. 记录：这一版 bit 的路径 + 哈希，写进测试记录表。

> 现状（2026-11-07 核对）：`prj/zynq_vision/.../impl_1/system2_wrapper.bit` 是 2026-10-29 10:50 的，
> 布线后 **WNS +0.802 ns**；`system_wrapper.xsa` 还是 10-18 的旧版，加完 AXI 要重新导出。

### A.1 已经改好的 RTL（本轮交付）

| 文件 | 作用 |
|---|---|
| `rtl/vision_regs_axi.v` | **新增**。AXI4-Lite 从口 + 结果快照 + 帧末中断 + 跨时钟同步 |
| `rtl/armor_vision.v` | **+2 个输出**：`result_extra[143:0]`（打包结果）、`frame_tick_o`（帧末单拍）。只加连线，不改任何判决逻辑 |
| `rtl/ov5640_lcd_zynq.v` | **+S_AXI 从口 + irq 端口**，例化 `vision_regs_axi`；`armor_vision` 的 4 个结果输出从悬空改成接出来 |
| `sim/tb_vision_regs_axi.v` | 自检 TB，**40 项检查，实测 ALL CHECKS PASSED** |
| `sim/run_regs_sim.bat` | 一键跑上面的 TB（约 30 秒） |
| `tools/patch_axi_a1.py` | 上面两个文件的补丁脚本（幂等，GBK 读写并回读校验） |

**回归状态（2026-11-07 实测，证据在 `doc/evidence/2026-11-07_a1/`）**

| 验证 | 命令 | 结果 |
|---|---|---|
| 新模块自检 | `sim/run_regs_sim.bat` | **ALL CHECKS PASSED (40 checks)** |
| Zynq 顶层 elaborate | `xelab ov5640_lcd_zynq`（FIFO IP 用临时 stub） | **Built simulation snapshot**，端口重连 0 error |
| 流水线全回归（改后） | `tb_armor_vision`，约 16 min | 4 项 FAIL |
| 流水线全回归（HEAD 基线） | 同上，用 `git show HEAD:rtl/armor_vision.v` | **同样 4 项 FAIL，且 FAIL 行逐字节相同** |

→ 那 4 项（相位 4 的 `bond_valid`、相位 10 的 `mov_flag`/`mov_lead_dir`/`mov_lead_amt`）
是**既有问题**，与本轮改动无关（本轮只加了输出端口和一根打包 assign）。
建议单独开一条 issue 修 TB 期望值或算法，别混进 A 线。

**时钟域**：视觉侧 `lcd_clk` 25 MHz，AXI 侧 `ui_clk`（FCLK_CLK0）100 MHz。
每帧把结果锁存一次（`hold`），同时翻转 `tog`；AXI 侧 2 级同步后取边沿，把 `hold` 打进 `snap`。
数据在整个帧周期（33 ms）内不动，所以"数据总线 + toggle 握手"在这里是安全的。

### A.2 寄存器表（PS 侧视角，32 位，基址由 Address Editor 分配）

| 偏移 | 名称 | 属性 | 内容 |
|---|---|---|---|
| 0x00 | ID | RO | `0x56495331`（"VIS1"），读到它说明 AXI 通路通了 |
| 0x04 | CTRL | RW | bit0 = SW_IRQ（写 1 自清，测试中断用）；bit1 = CLR_CNT（写 1 自清） |
| 0x08 | IRQ_EN | RW | bit0 = 帧末中断使能 |
| 0x0C | IRQ_STATUS | W1C | bit0 = 帧末事件（写 1 清零） |
| 0x10 | SCRATCH | RW | 32 位读写测试寄存器（验证写通路 + WSTRB） |
| 0x14 | FRAME_CNT | RO | 复位以来帧数（32 位） |
| 0x18 | FPS | RO | 最近 1 s 窗口内的帧数 |
| 0x1C | FLAGS | RO | [0]valid [1]dist_ok [2]pred_ok [3]adapt_ok [4]moving [5]far_small [6]disp_bin [15:8]fill_q8 [18:16]blob_cnt |
| 0x20 | CX | RO | 灯心 x |
| 0x24 | CY | RO | 灯心 y |
| 0x28 | AX | RO | 瞄准点 x |
| 0x2C | AY | RO | 瞄准点 y |
| 0x30 | BW | RO | 目标宽（投影框，像素） |
| 0x34 | AREA | RO | 团块面积 |
| 0x38 | DIST_CM | RO | 表观宽反推距离（cm） |
| 0x3C | DROP_PX | RO | 下坠补偿（像素） |
| 0x40 | VX_Q4 | RO | 速度估计 Q4（有符号） |
| 0x44 | VY_Q4 | RO | 同上 |
| 0x48 | PX | RO | 预测灯心 x |
| 0x4C | PY | RO | 预测灯心 y |

> **本轮只做读 + 中断**。阈值/参数写入留到 A2：现在 UART `0xAA addr data` 已经能改 19 个参数，
> A2 再把 `reg_file` 的字地址接到 AXI 写通道，避免这轮同时改算法内部。

### A.3 Vivado 里要你做的操作（GUI，约 30 分钟）

> ⚠️ 已知坑：批处理模式建 BD 会报 `Failed to resolve reference ... ov5640_lcd_zynq`，
> **一律在 GUI / GUI 的 Tcl Console 里做**。

0. **把新文件加进工程**（不然模块引用解析不到）：Zynq 工程里
   `Add Sources → Add or create design sources → Add Files → rtl/vision_regs_axi.v`。
   （`tools/add_sources_vivado.tcl` 只针对 7A35T 的 `prj/ov5640_lcd.xpr`，不管 Zynq 工程。）
1. 打开 `prj/zynq_vision/zynq_vision.xpr`，打开 `system2.bd`。
2. **刷新模块端口**（因为 `ov5640_lcd_zynq` 的端口变了）：
   右键 `vision_top` → **Refresh Module Reference**。
   （若报错就删掉这个模块，重新 `Add Module` 选 `rtl/ov5640_lcd_zynq.v`。）
   刷新后应能看到一个新的接口口 **S_AXI** 和一个单线 **irq**。
3. 双击 `processing_system7_0` → **PS-PL Configuration**：
   - AXI Non Secure Enablement → GP Master AXI Interface → 勾选 **M AXI GP0**
   - Interrupts → Fabric Interrupts → PL-PS Interrupt Ports → 勾选 **IRQ_F2P**（宽度 1）
4. 连 AXI：从 PS 的 `M_AXI_GP0` 拖到 `vision_top` 的 `S_AXI`，弹窗选 **Run Connection Automation**
   （自动插 SmartConnect + 时钟/复位）。若手动插，用 `smartconnect`，`aclk`/`aresetn` 接 FCLK_CLK0 那一路。
5. 连中断：`Ctrl+I` 加 `xlconcat`（In0 宽度 1），`vision_top/irq → xlconcat/In0`，`xlconcat/dout → ps7/IRQ_F2P`。
6. **Address Editor**：给 `vision_top/S_AXI` 分配地址（通常自动给 `0x43C0_0000`，范围 4K）。
   **把这个基址记下来**，后面全部命令都用它。
7. `F6` **Validate Design**（必须 0 error）→ **Generate Output Products**（Global）
   → Run Synthesis → Run Implementation → Generate Bitstream。
8. 导出硬件：**File → Export → Export Hardware**，勾选 **Include bitstream**，导出新 XSA（覆盖 `system_wrapper.xsa`）。

### A.4 下载与第一步验证（XSCT，不需要 Vitis 工程）

```tcl
connect
targets -set -filter {name =~ "APU*"}
rst -system
after 2000
source C:/Users/DUANboyang/Desktop/FPGA4dart/prj/zynq_vision/zynq_vision.gen/sources_1/bd/system2/ip/system2_processing_system7_0_0/ps7_init.tcl
ps7_init
ps7_post_config
fpga -file C:/Users/DUANboyang/Desktop/FPGA4dart/prj/zynq_vision/zynq_vision.runs/impl_1/system2_wrapper.bit
```

然后**在这一步就验 AXI 通路**（不用写任何 C）：

```tcl
# 基址按 Address Editor 实际值替换，示例 0x43C00000
mrd 0x43C00000          ;# ID，期望 0x56495331
mwr 0x43C00010 0xDEADBEEF
mrd 0x43C00010          ;# 期望 0xDEADBEEF
mrd 0x43C00014          ;# FRAME_CNT，应随帧率增长
mrd 0x43C00020          ;# CX
mrd 0x43C0001C          ;# FLAGS
```

**判据**：ID 读对 = AXI 读写都通（ID 是只读、SCRATCH 是读写，两条路径都覆盖）。

### A.5 无相机自检（C2，最值得做的一步）

不用相机、不用灯，用板上的 `syn_target` 产生运动目标：

1. 通过 **PL 串口**（USB-TTL，115200）发 UART 命令打开合成靶标：
   `AA 0F 01 0E`（`0xAA addr data addr^data`，addr=0x0F，data=01，校验=0x0E）。
2. 再 `mrd 0x43C00020`（CX）连续读几次：**CX 应该按合成速度移动**；
   `mrd 0x43C0001C` 的 bit0（valid）应为 1。
3. `mrd 0x43C00014` 应该每帧 +1。

**判据**：CX 随合成目标移动、valid=1、FRAME_CNT 单调增长。这一条通了就说明
"视觉结果 → 快照 → 跨时钟 → AXI 寄存器"整条链路是对的。

### A.6 中断验证（裸机，Vitis 2020.2）

用新 XSA 建 platform（`File → New → Platform Project`），加一个 Application，
把 `sw/axi_a1_test.c` 加进去（见仓库 `sw/` 目录）。它会：

1. 打印 ID / SCRATCH 回读；
2. 初始化 `XScuGic`，把 `IRQ_F2P` 对应的 61 号中断（`XPS_FPGA0_INT_ID`）挂到 ISR；
3. 使能 `IRQ_EN`，等 100 帧，打印实际中断次数、CX、FLAGS；
4. 做一次 `SW_IRQ` 人为触发 + W1C 清零的自测。

**判据**（必须写数字）：
- ISR 计数在 60 s 内 = FPS ± 1%；
- 10 万帧不丢（用 `FRAME_CNT` 与 ISR 计数对比，差值 ≤ 1）；
- W1C 写 1 后中断线确实拉低（读 `IRQ_STATUS` = 0 且 `irq` 不再触发）。

### A.7 A 线常见坑

| 现象 | 原因 / 处理 |
|---|---|
| `mrd` 读到全 0 或全 F | 基址错（看 Address Editor）／GP0 没勾上／BD 没重新 Generate |
| 读到 `0x00000000` 但 ID 应为魔数 | `vision_top` 模块参考没刷新，S_AXI 根本没连上 |
| 一读就挂死 | SmartConnect 没插、时钟没接（`s_axi_aclk` 必须接 FCLK_CLK0） |
| 中断不进 | `IRQ_F2P` 没勾 / `xlconcat` 没接 / GIC 里没使能 61 号 / `IRQ_EN` 没写 1 |
| 中断进一次就不再进 | ISR 里没写 `IRQ_STATUS` W1C 清零（这是电平中断） |
| CX 一直是 0 | `syn_target` 没开；或 `valid` 一直 0（先看 FLAGS bit0） |
| 时序不过 | 先跑 `report_timing` 看新加的逻辑；`vision_regs_axi` 只有单周期 AXI 逻辑，正常不会成为 WNS 瓶颈 |

---

## 2. B 线：PetaLinux 2020.2（可与 A 并行）

### B.1 资源

| 项 | 占用 |
|---|---|
| 安装器 `.run` | 约 7–8 GB（装完可删） |
| 装好的工具 | 约 10–12 GB |
| 一个工程 `build/` | 30–40 GB |
| **建议** | **VM 虚拟盘 100 GB（thin），8 GB 内存，4 核** |

**宿主必须是 Ubuntu 18.04（或 16.04）**；Ubuntu 24.04 / 20.04 不在 2020.2 支持列表里。
本机 C: 现有 71.2 GB、D: 剩 58.2 GB（2026-11-07 已删除 Ubuntu 24.04 + ROS2 Jazzy 的 VM，腾出 34.6 GB）；
**Linux 侧不要装 Vivado/Vitis**（Windows 的 `D:\Xilinx` 已有），这一项省 30 GB 以上。

VM 已建好（2026-11-07）：`D:\DUANboyang\VMs\ubuntu1804_petalinux\ubuntu1804_petalinux.vmx`，
100 GB thin / 8 GB 内存 / 4 核 / NAT。ISO 在 `D:\DUANboyang\VMs\iso\ubuntu-18.04.6-desktop-amd64.iso`，
sha256 `f730be58…ff11` 与官方 SHA256SUMS 一致。装完系统后跑 `doc/petalinux_1804_setup.sh` 装依赖。

**2026-11-09 已装好**：PetaLinux 2020.2 装在 `~/petalinux`（9.2 GB，`--platform arm` 只装 zynq）。
首次构建 `dart_7020` 工程（XSA = 10/18 的 PL-only 版，`xc7z020clg400-2`）：
`petalinux-build` 50 分钟、0 错误 → `image.ub` 11 MB；`petalinux-package --boot` → `BOOT.BIN` 4.7 MB。
产物已拉回主机 `petalinux/out/`。**串口上板验证待做**（D2 的判据只完成了一半）。

### B.2 步骤

1. VMware 建 Ubuntu 18.04.6 桌面版，100 GB 盘；装 `build-essential`、`zlib1g:i386`、
   `libncurses5`、`chrpath`、`gcc-multilib`、`python3` 等（按 UG1144 清单）。
   `sudo dpkg-reconfigure dash` 选 **No**（PetaLinux 脚本要用 bash）。
2. 装 PetaLinux 2020.2（AMD 账号登录，[归档页](https://www.xilinx.com/support/download/index.html/content/xilinx/en/downloadNav/embedded-design-tools/archive.html)）：
   `./petalinux-v2020.2-final-installer.run -d ~/petalinux`，同意 EULA。
3. 建工程（**等 A 线的新 XSA**）：
   ```bash
   petalinux-create --type project --template zynq --name dart_7020
   cd dart_7020
   petalinux-config --get-hw-description=<新XSA 的目录>
   ```
4. **直接复用飞镖的配方**：把 `dart2026_-open-source/dart_-linux/project-spec/meta-user/`
   里的 `recipes-bsp/device-tree`、`pl-custom.dtsi`、`system-user.dtsi` 拷过来按本工程改。
   （飞镖的设备树已有 ov9282/vcap/vdma/spi/sdhci 节点，驱动 recipe 在
   `dart_-linux/application/video_manager/`、`.../pwm_6ch/`。）
5. `petalinux-build` → `petalinux-package --boot --fsbl ... --fpga ... --u-boot --force`。
6. **判据**：串口登录 root；`dmesg` 里 probe 成功；`/proc/interrupts` 里中断计数在涨；
   跑完 `petalinux-build -x mrproper` 回收 20–30 GB。

### B.3 B 线的坑

- 工程别放 VMware 共享文件夹（Yocto 会报错且极慢），放 VM 内部盘。
- 别开快照，会翻倍占盘。
- 2020.2 的旧库依赖要装全，否则 `petalinux-build` 在 do_compile 阶段挂。

---

## 3. C 线：接口对齐与资源（不阻塞任何人）

### C.1 契约一页纸

飞镖软件对 PL 的期望（全部来自 `dart2026_-open-source`）：

| 飞镖侧 | 文件 | 本工程对应 |
|---|---|---|
| `/dev/video_manager`，ioctl：SET/GET_THRESHOLD、GET_BOND_NUM、GET_BONDS、GET_FPS | `dart_-application/application/preiph/video.h` | `IRQ_STATUS`/`IRQ_EN`/`FLAGS`/`CX`…；阈值 A2 再补 |
| 内核驱动寄存器语义：reg0={top,bottom}、reg1={left,right}、reg2=B、reg3={G[25:16],R[9:0]} | `dart_-linux/application/video_manager/video_manager.c` | 我们的 FLAGS/CX 是"圆心 + 宽"，A2 再做 `left/right/top/bottom` 的映射（或改应用层） |
| `/sys/.../chN_{arr,cmp,en}` | `dart_-application/application/preiph/servo.c` | 直接复用 `pwm_6ch` IP + 驱动（**不需要重写**） |
| BMI088 走 `/dev/spidev0.0` / `0.1` | `dart_-application/application/preiph/bmi088.c` | 飞镖做法就是 spidev，不用写内核驱动 |
| 遥测 TCP 8080 / 图传 UDP 5004 | `dart_-application/application/preiph/network.c` | PS 侧网络，与 PL 无关 |

**关键结论**：ZYNQ 版要"长得像 dart 的 `video_manager`"，而不是另造接口。

### C.2 xc7z010 资源收口（每个里程碑都要做一次）

- 真机是 **XC7Z010**：LUT 17.6K / FF 35.2K / BRAM 36（60 个 RAMB36）/ DSP 80。
- 飞镖原设计已占 **LUT 68.28% / BRAM 40.83%**；本工程视觉 add-on OOC 是 **LUT 7.76K（≈7010 的 44%）**。
  → **两者加起来必超**，所以 ZYNQ 版定位是"**替代** dart 那一层（Threshold+FindBond）"，不是叠加。
- `TACC_EN` 上 7010 时**必须保持 0**（打开要吃 24 个 RAMB36 = 40% BRAM）。
- 做法：`tools/synth_check_vision.tcl` 把 `-part` 改成 `xc7z010clg400-1` 跑 OOC，数字贴进测试记录。

### C.3 自动化判据（G3）

把能自动化的判据做成脚本，一条命令出 PASS/FAIL：
寄存器遍历（ID/SCRATCH/全部 RO）、中断计数、`FRAME_CNT` 与 ISR 计数比对、
UART/AXI 双路对拍（C7）、FPS 统计。

---

## 4. 里程碑与依赖

| 里程碑 | 内容 | 依赖 | 状态 |
|---|---|---|---|
| M0 | bit 上板、LCD 出图、PL UART 有帧 | — | 待确认（10-29 版是否上过板） |
| M1 | **AXI ID / SCRATCH 读写通**（XSCT `mrd` 即可） | A.3 BD 改造 | 本轮 |
| M2 | **无相机自检**：`syn_target` → CX 在动、valid=1、FRAME_CNT 增长 | M1 | 本轮 |
| M3 | **中断正式化**：裸机 ISR 计数 = 帧率 ±1%；W1C 能清 | M2 | 本轮 |
| M4 | 接相机 + 反光回归（F4） | M3 | 下一轮 |
| M5 | 帧通路到 DDR + 图传（B6/D7） | M1 | 与 B 并行 |
| M6 | Linux 主线：驱动、设备树、PWM、IMU | M0 + B 环境 + 新 XSA | B 线 |
| M7 | 应用联调 + 端到端时延 + 长稳 | M3~M6 | 最后 |
| M8 | 7010 资源核算与归档 | 每个里程碑 | 持续 |

**最短可用 demo**：M0 → M1 → M2 → M3，即"没有 PS 软件栈，也能在 7020 上用 AXI 寄存器 + 中断
把视觉结果交给 ARM，并证明延迟"。这条线的价值是验证飞镖最核心的 PL↔PS 契约。

---

## 5. 变更记录

- 2026-11-07：建立本文件；A 线第一阶段 RTL 完成（`vision_regs_axi.v` + 两个补丁），
  TB `sim/tb_vision_regs_axi.v` 实测 **40/40 通过**；Zynq 顶层重新 elaborate 通过。
