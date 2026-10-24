# ZYNQ 上板操作方法（XC7Z020 / dart 视觉验证）

本文记录从「工程构建完成」到「板子上跑起来」的固定操作，便于复现。
器件：XC7Z020CLG400-2；工具：Vivado / Vitis 2020.2（`D:\Xilinx\`）。

## 0. 关键路径

| 项 | 路径 |
|---|---|
| 工程 | `prj/zynq_vision/zynq_vision.xpr` |
| 顶层 | `system2_wrapper`（Block Design：`system2`） |
| 约束 | `prj/zynq_challenger.xdc` |
| 比特流 | `prj/zynq_vision/zynq_vision.runs/impl_1/system2_wrapper.bit` |
| PS 初始化脚本 | `prj/zynq_vision/zynq_vision.gen/sources_1/bd/system2/ip/system2_processing_system7_0_0/ps7_init.tcl` |

> 如果重建过 BD，`system2` 这个名字会变，`ps7_init.tcl` 的路径也要跟着改；
> 在 `prj/zynq_vision/zynq_vision.gen` 下搜 `ps7_init.tcl` 即可。

## 1. 构建（Vivado）

1. 打开 `zynq_vision.xpr`。
2. 打开 `system2.bd`，按 **F6** Validate Design，确认 0 error。
3. 右键 `system2` → **Generate Output Products**，Synthesis Options 选 **Global**。
4. **Run Synthesis** → **Run Implementation** → **Generate Bitstream**。
5. 检查：Messages 里 0 Errors；Timing Summary 的 WNS ≥ 0。

产物就是上表里的 `.bit` 和 `ps7_init.tcl`。

## 2. 下载（XSCT，不需要 Vitis 工程）

打开 `D:\Xilinx\Vitis\2020.2\bin\xsct.bat`，依次执行：

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

各行的作用：

| 命令 | 作用 |
|---|---|
| `connect` | 连本机 hw_server（JTAG） |
| `targets -set -filter {name =~ "APU*"}` | 选中 ARM Cortex-A9（PS） |
| `rst -system` | 复位整个系统（PS + PL） |
| `after 2000` | 等 2 s，让复位稳定 |
| `source ...ps7_init.tcl` | 载入 PS7 初始化脚本（含 DDR 时序/时钟配置） |
| `ps7_init` | 按脚本写 PS 寄存器：时钟、DDR3、MIO…… |
| `ps7_post_config` | 解除 PS 对 PL 的隔离（释放 FCLK/RESET） |
| `fpga -file ....bit` | 下载 PL 比特流 |

**顺序不能反**：必须先 `ps7_init` 把 DDR 初始化好，再加载 PL。
本设计的帧缓存走 PS 的 `S_AXI_HP0`，DDR 没初始化时 PL 读写不到，画面会卡死或不亮。

## 3. 上板检查

1. LCD 背光应亮（`lcd_bl` 常 1），随后出现相机画面。
2. 串口 115200：**PL 的 UART 走 F19/F20 排针**，需要外接 USB-TTL；
   板载 USB 口接的是 PS 的 MIO14/15，看不到 PL 串口。
3. 相机 PCLK 可在 2x9 插头第 8 列下排（K17）测量，正常应有几十 MHz。

## 4. 常见坑（都踩过）

| 现象 | 原因 / 处理 |
|---|---|
| Vivado 批处理建 BD 报 `Failed to resolve reference ... ov5640_lcd_zynq` | 批处理模式下 module_ref 解析有问题；改用 GUI 或 GUI 的 Tcl Console 执行 |
| `S_AXI_HP0'(:::)` 与 `M_AXI` 类型不兼容 | PS7 的 xci 与 BD 不同步；重建 BD（本项目已用 `system2`） |
| PS 块上多出 `GMII_ETHERNET_0` | ENET0 被误设为 EMIO；本板 PHY 接 MIO16–27，测试阶段直接关掉 ENET0 |
| `Inout buffer is not created ... lcd_rgb[x]` | `lcd_rgb` 是 inout 总线，综合阶段的已知 critical warning，不影响出图 |
| 只下 bit 没跑 `ps7_init` | DDR 未初始化，帧缓存不通；按第 2 节顺序重来 |

## 5. 变更记录

- 2026-10-23：建立本流程；用 `system2` BD（PS7 + proc_sys_reset + vision_top，`S_AXI_HP0` ↔ `M_AXI`）首次跑通综合/实现。
