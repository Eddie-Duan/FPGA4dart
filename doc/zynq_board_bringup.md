# Zynq 板 Linux 上板启动记录（2026-11-11 打通）

> 板子：Alientek Mini Zynq（正点原子迷你 Zynq，XC7Z020，1 GB DDR3，Silicon v3.1）
> 系统：PetaLinux 2020.2 / Linux 5.4.0-xilinx-v2020.2 / initramfs

## 一、结论先说

**已在本板子上跑通了我们的 PetaLinux 系统**：

```
Linux version 5.4.0-xilinx-v2020.2 (oe-user@oe-host) (gcc 9.2.0) #1 SMP PREEMPT
Memory: 1004 MB
fpga_manager fpga0: Xilinx Zynq FPGA Manager registered
PetaLinux 2020.2 dart_7020 /dev/ttyPS0
dart_7020 login:
```

登录：`root` / `root`

## 二、最关键的坑：**必须先配置 PL，再跳内核**

**症状**：U-Boot 里执行 `bootz`（无论加载厂商内核还是我们的内核），
打印完 `Booting using the fdt blob ...` 后**彻底静默**，连内核第一行都没有。

**原因**：板上 PL 里有 AXI 从机（`vision_top/M_AXI → PS S_AXI_HP0`）。
**PL 未被配置时，任何对 PL 地址空间的访问都会让 AXI 总线挂死**，
而处理器随即被卡住，所以连串口都停了。

**解决**：跳内核之前必须先用 U-Boot 把 bitstream 烧进 PL：

```
load mmc 0 0x100000 system.bit        # 加载 bitstream 到 DDR
fpga loadb 0 0x100000 0x400000        # 编程 PL（这一步是之前漏掉的）
```

配置成功后 `/sys/class/fpga_manager/fpga0/state` 读出 `operating`。

## 三、可用的手动启动流程

在 U-Boot 提示符（上电后按任意键打断，`bootdelay=10`）执行：

```text
mmcinfo
load mmc 0 0x100000  system.bit            # bitstream → DDR
fpga loadb 0 0x100000 0x400000             # 配置 PL
load mmc 0 0x2080000 our_zImage            # 内核（注意不是 0x3000000）
load mmc 0 0x2000000 our_system.dtb        # 设备树
load mmc 0 0x4000000 our_rootfs            # initramfs
setenv bootargs console=ttyPS0,115200 earlycon root=/dev/ram0 rw
bootz 0x2080000 0x4000000 0x2000000
```

地址来源：厂商 U-Boot 默认环境里的
`kernel_load_address=0x2080000`、`devicetree_load_address=0x2000000`、
`ramdisk_load_address=0x4000000`、`bitstream_load_address=0x100000`。

## 四、已固化的自动启动（写入 SPI Flash）

U-Boot 环境已保存（`saveenv` → `Saving Environment to SPI Flash... done`）：

```text
bootcmd=run open_led; mmcinfo;
  load mmc 0 0x100000 system.bit; fpga loadb 0 0x100000 0x400000;
  load mmc 0 0x2080000 our_zImage;
  load mmc 0 0x2000000 our_system.dtb;
  load mmc 0 0x4000000 our_rootfs;
  setenv bootargs console=ttyPS0,115200 earlycon root=/dev/ram0 rw;
  bootz 0x2080000 0x4000000 0x2000000
bootdelay=10
```

**上电即自动进入我们的系统，无需任何人工操作。**

> 注意：现在用的 `system.bit` 是**厂商 2021 年的 bitstream**（PL 里不是我们的
> `vision_top` 设计）。要换成我们自己的，把 `images/linux/system.bit` 拷到卡上
> 覆盖同名文件即可，其余命令不用改。

## 五、SD 卡布局（启动盘 = 分区 1，FAT32，卷标 boot）

| 文件 | 大小 | 作用 |
|---|---|---|
| `BOOT.BIN` | 0.61 MB | **厂商版** FSBL+U-Boot（我们的版本目前不可用，见第六节） |
| `our_zImage` | 4.13 MB | 我们的内核 |
| `our_system.dtb` | 18 KB | 我们的设备树 |
| `our_rootfs` | 6.89 MB | 我们的 initramfs |
| `system.bit` | 3.86 MB | bitstream（当前是厂商的） |
| `image.ub` | 11 MB | 我们的 FIT（备用，当前流程不用） |
| `zImage` / `system.dtb` | — | 厂商内核/dtb（回滚用） |

分区 2（ext4，14.5 GB）是厂商 rootfs，我们的 initramfs 方案用不到。

## 六、仍未解决：我们自己的 BOOT.BIN 不启动

| 事实 | 证据 |
|---|---|
| 带 `FSBL_DEBUG_INFO` 的 FSBL 零输出 | 单独打包 104 KB 的 "FSBL-only" BOOT.BIN，串口全静默 |
| 厂商 BOOT.BIN 同卡同拨码正常 | 说明卡、启动模式、BootROM 都没问题 |
| FSBL 体积 81 KB | 远小于 192 KB OCM 上限，不是超标 |
| 我们的内核/dtb/initramfs 完好 | 走厂商 U-Boot 能完整启动（见上） |

**嫌疑**：`ps7_init()` 的 DDR / 时钟 / MIO 配置与这块板子不匹配，
导致 FSBL 在第一行打印之前就挂住。

**下一步**：在 Vivado 里把 `prj/zynq_vision` 的 Zynq PS7 配置对齐正点原子
Mini Zynq 的预设（DDR3 MT41K256M16、1 GB、33.333 MHz），重新导出 XSA，
重跑 `petalinux-config --get-hw-description` 后重建 BOOT.BIN。

## 七、板子实测硬件信息

```text
CPU        : ARMv7 Cortex-A9 (part 0xc09), revision r3
Hardware   : Xilinx Zynq Platform, Revision 0003
DRAM       : 1 GiB (ECC disabled)
UART0      : e0000000.serial → ttyPS0 (irq 24)   ← 板载 USB-UART
UART1      : e0001000.serial → ttyPS1 (irq 25)
SD         : mmc0 @ e0100000 (SDHCI, ADMA)
QSPI       : w25q256 32 MiB，分区 boot/bootenv/bitstream/device-tree/kernel/space
FPGA       : fpga_manager fpga0 = operating
```

## 八、回滚到厂商系统

U-Boot 里执行：

```text
setenv bootcmd 'run open_led; run $modeboot || run distro_bootcmd'
saveenv
```

（`modeboot=sdboot` 会加载 `system.bit` + 厂商 `zImage` + `system.dtb`，
rootfs 用分区 2 的 ext4。）

## 九、待办

- [x] 用我们自己的 `system.bit` 替换卡上的厂商 bitstream
- [ ] 修好我们自己的 BOOT.BIN（PS7 配置对齐后重做）
- [ ] PL 侧补 IP（VDMA/SPI/PWM/video_manager）→ 新 XSA → 设备树加节点 → 驱动 probe
- [ ] 板级验证清单见 `doc/petalinux_verify.md`

## 十、换上我们自己的 bitstream 后实测（2026-11-11）

把 `images/linux/system.bit`（`vision_top` 设计）写入卡的同一个文件名，U-Boot
`bootcmd` 不用改，上电自动加载。

**四个 LED 全部观察一遍**（板上有 PW / DONE / PS / PL 四个灯）：

| LED | 状态 | 含义 |
|---|---|---|
| PW | 亮 | 电源正常 |
| **DONE** | **亮** | **我们的 bitstream 加载成功**（FPGA 配置完成） |
| **PS** | **亮** | PS 侧系统运行中 |
| **PL** | **闪烁** | **PL 逻辑在跑**（有独立时钟，用户逻辑生效） |

**结论：我们的 PS7 配置、bitstream、内核、rootfs 在真板子上全部正常工作。**

LCD 仍然没有画面。这不是启动问题，属于设计层面，可能原因：

1. `vision_top` 需要摄像头输入才有输出（摄像头是否接入/供电）
2. `vision_top` 内部没有 LCD 驱动模块（那 LCD 本来就是黑的）
3. LCD 排线/背光供电

判据：在 Vivado 里打开 `vision_top` 的端口定义，确认它是否有 LCD 相关输出
（`lcd_*` / `hsync` / `vsync` / `rgb*` 等）。没有的话 LCD 黑屏是正常的。

## 十一、串口 USB 链路的已知问题

调试过程中 CH340 多次出现：
- `usb 2-2.1: failed to send control message: -110`（ETIMEDOUT）
- 打开 `/dev/ttyUSB0` 报 `Input/output error`
- 板子断电时整条 USB 链路掉线，需要重新连进虚拟机

处理办法：在虚拟机里重新绑定 USB 设备即可恢复

```bash
p=$(ls -d /sys/bus/usb/devices/*/ | while read d; do \
      [ -e "$d/idVendor" ] && [ "$(cat $d/idVendor)" = "1a86" ] && basename $d; done | head -1)
echo -n "$p" > /sys/bus/usb/drivers/usb/unbind && sleep 2
echo -n "$p" > /sys/bus/usb/drivers/usb/bind
```

如果频繁发生，优先怀疑 **USB 线 / USB 口供电或接触**（这块板子靠 USB 供电，
Zynq + LCD 峰值电流可能超过普通 USB 口的 500 mA）。建议用后置 USB 3.0 口，
或改用板子的独立 DC 供电口。

