# PetaLinux 上板启动问题排查记录（2026-11-10）

## 结论摘要

| 项 | 状态 | 证据 |
|---|---|---|
| 硬件 | ✅ 正常 | 厂商镜像正常启动，LCD 显示 ALIENTEK OS |
| SD 卡 / 启动模式 | ✅ 正常 | 拨码 00 = SD 启动，厂商 BOOT.BIN 能从卡引导 |
| UART 串口 | ✅ 正常 | `ttyUSB`(CH340)，115200，能登入厂商 Linux |
| 我们的 `image.ub` | ✅ 完好 | 厂商 U-Boot FIT 校验 kernel/ramdisk/fdt 全部 sha256 OK；qemu 能跑到登录符 |
| **我们的 `BOOT.BIN`** | ❌ **FSBL 不运行** | 带 `FSBL_DEBUG_INFO` 却零输出；单独打包 FSBL-only 镜像同样零输出 |

**根因方向：FSBL 的 `ps7_init()` 与这块板子的 PS 配置不匹配（DDR 或时钟参数），在打印第一行之前就挂住了。**

## 关键实测数据

### 板子真实信息（从厂商 Linux 读出）

```
model      : Alientek Mini Zynq Development Board
soc revision: 0x3 (Zynq-7000 v3.1)
DRAM       : 1 GiB (ECC disabled)
console    : serial@e0000000  (UART0, MIO14/15)  ← 板载 USB-UART 接这里
QSPI       : w25q256 32MiB, 分区 boot/bootenv/bitstream/device-tree/kernel/space
SD         : mmcblk0, p1=100M FAT32("boot"), p2=14.5G ext4(rootfs)
厂商 U-Boot: 2018.01, Xilinx Zynq ZC702, bad CRC -> default env
```

### 我们镜像的关键参数

```
BOOT.BIN  : FSBL(81KB text+data, OCM 上限192KB 未超) + system.bit + u-boot
image.ub  : kernel 4.1MiB + ramdisk 6.9MiB + fdt 17.9KiB
dtb       : serial0 = /amba/serial@e0000000  (已从 UART1 改为 UART0)
bootargs  : console=ttyPS0,115200 earlycon root=/dev/ram0 rw
```

## 已排除的可能

- ❌ 串口接错：厂商 U-Boot 与内核都打印在 UART0，我们已改到 UART0
- ❌ 卡坏 / 写坏：MD5 校验一致，厂商 BOOT.BIN 同卡可用
- ❌ 拨码错：00 = SD 启动已验证
- ❌ FSBL 超标：81 KB < 192 KB OCM
- ❌ 内核坏：FIT 校验通过，qemu 能启动
- ❌ U-Boot 串口没改：`u-boot.dtb` 里 `serial0 = serial@e0000000` 已确认

## 下一步（无需硬件即可推进）

1. **从厂商 BOOT.BIN 中提取 FSBL**（bootgen 分区表解析），反汇编 `ps7_init`，
   与我们的 `zynq_fsbl.elf` 中的 `ps7_init` 逐寄存器对比，重点看：
   - DDR 控制器参数（`DDR_*` 寄存器：时序、PHY 训练、DDR 型号）
   - PLL / 时钟（ARM PLL、DDR PLL、IO PLL 分频）
   - MIO 配置（UART/SPI/SD 的 MIO 复用）
2. 按对比结果在 **Vivado 里改 Zynq PS7 配置**（`prj/zynq_vision`），重新导出 XSA
3. 重跑 `petalinux-config --get-hw-description=<新XSA>` → 重建 → 重新打包

## 快速回滚

卡上恢复 `D:\DUANboyang\VMs\backup_tf_vendor\BOOT.BIN`（0.61MB）即可让板子回到厂商系统。
