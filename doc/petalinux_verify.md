# PetaLinux 接入后的验证清单

> 对应 `ZYNQ_TEST_PLAN.md` 的 D 组。分三层：**构建级**（不用硬件）、**模拟级**（不用硬件）、**板级**（要板子）。

---

## 第 1 层：构建级（不需要板子，几分钟）

**这些证明"工具链和配置是对的"，不能证明"能跑"。**

```bash
source ~/petalinux/settings.sh
cd ~/dart_7020

# 1. 产物齐全
ls -lh images/linux/{BOOT.BIN,image.ub,system.dtb,zynq_fsbl.elf,u-boot.elf}

# 2. 设备树里 PS 节点是否按 XSA 生成
dtc -I dtb -O dts -o /tmp/sys.dts images/linux/system.dtb
grep -E 'compatible = "xlnx,zynq-7000"' /tmp/sys.dts        # 器件对不对
grep -oE '(serial|ethernet|mmc|spi|i2c|watchdog)@[0-9a-f]+' /tmp/sys.dts | sort -u
grep -A3 'memory {' /tmp/sys.dts                            # DDR 容量
grep -A3 'chosen {' /tmp/sys.dts                            # bootargs
grep -cE 'amba_pl|axi_' /tmp/sys.dts                        # PL 节点数（0 = PL 不可见）

# 3. rootfs 里有什么包（驱动、库是否真的进了镜像）
grep -E 'video-manager|pwm-6ch|opencv|gstreamer' images/linux/rootfs.manifest

# 4. 驱动模块是否编出来
find images/linux -name '*.ko' | head
find components/yocto -name 'video_manager.ko' -o -name 'pwm_6ch.ko' | head

# 5. BOOT.BIN 的分区构成（FSBL / bit / uboot 各一段）
bootgen -arch zynq -image boot.bif -o /dev/null 2>&1 | head -5
```

**判据**：文件都在；`dtb` 里能看到 `compatible = "xlnx,zynq-7000"` 和 PS 外设节点；`.ko` 存在；`image.ub` 大小合理（10–20 MB）。

### 基线实测（2026-11-09，`dart_7020` 首次构建）

| 项 | 实测值 | 说明 |
|---|---|---|
| `BOOT.BIN` | 4.7 MB | FSBL + bit + U-Boot |
| `image.ub` | 12 MB | kernel + dtb + initramfs |
| `system.dtb` | 18 KB | 默认配置 |
| `rootfs.manifest` | 146 个包 | — |
| DDR | `reg = <0x0 0x40000000>` → **1 GB** | 和 XSA 里 PS7 配置一致 |
| bootargs | `console=ttyPS0,115200 earlycon root=/dev/ram0 rw` | 从 initramfs 启动 |
| PS 外设 | 2×ethernet、2×i2c、2×mmc、2×serial、3×spi、watchdog | 都来自 XSA 的 PS7 配置 |
| **PL 节点数** | **0**（`amba_pl`/`axi_` 一次都没出现） | ⚠️ 见下 |

> ⚠️ **PL 在设备树里完全不可见**。`vision_top` 是自定义 RTL 模块，Vivado 不会给没有 DT 元数据的 IP 自动生成 `amba_pl` 节点。所以现在烧进板子：PS 能跑、PL 逻辑也在跑（bitstream 已加载），但 **Linux 侧看不到任何 PL 外设**。
>
> 将来接 PL 有两条路：① 把 PL IP 打包成 Vivado IP（带 device-tree 元数据），Vivado 自动生成节点；② 手写 `pl-custom.dtsi`，自己给 `compatible` + `reg`（驱动要靠它 probe）。**我们的 `video_manager` / `pwm_6ch` 走第 ② 条。**

---

## 第 2 层：模拟级（不需要板子，能验证"Linux 能不能起来"）

PetaLinux 自带 qemu，可以只验证 **kernel + rootfs 启动链**，不涉及 PL。

```bash
source ~/petalinux/settings.sh
cd ~/dart_7020
petalinux-boot --qemu --kernel        # 起内核，看是否到 shell
```

**判据**：
- 串口输出里出现 `Booting Linux on physical CPU 0x0`、`Freeing unused kernel memory`
- 能进到登录提示符，root 能登（密码在 `petalinux-config` 里设的）

**局限**：qemu 的 zynq 模型只有 PS，**PL 和自定义 IP 完全不模拟**，所以驱动 probe、VDMA、中断这些都验不了。

---

## 第 3 层：板级（必须有板子 + SD 卡 + USB 串口）

这层才对应 `ZYNQ_TEST_PLAN.md` 的 D2~D8。

### 3.1 启动链（D2）

把 `BOOT.BIN` 和 `image.ub` 放进 SD 卡第一个分区（FAT32），插板子上电，串口 **115200 8N1** 接上。

**判据（按顺序看串口）**：
```
U-Boot 2020.01 ...          ← FSBL 过了，U-Boot 起来
Loading kernel from FIT ... ← image.ub 被正确识别
Booting Linux on ...        ← 内核接管
Freeing unused kernel memory
petalinux login:            ← rootfs 起来了
```
登进去后：
```bash
cat /proc/cpuinfo | head -5      # 型号应是 XC7Z020
free -m                          # 内存容量和实际板子一致
cat /proc/iomem | grep -i "system ram"
```

### 3.2 PS 外设（D2 后半）

```bash
lsblk                     # SD 卡识别
ip a                      # 网口（如果有 GEM）
cat /sys/kernel/debug/clk/clk_summary | head -20   # 时钟树，确认 PS 时钟对
dmesg | grep -iE 'mmc|eth|uart|i2c|spi'            # 外设 probe 日志
```

### 3.3 PL 与驱动（D3~D5）

```bash
# 设备树节点是否真的进内核
ls /sys/firmware/devicetree/base/ | grep -E 'video|pwm|spi|i2c'
cat /sys/firmware/devicetree/base/soc/*/compatible 2>/dev/null

# 驱动是否 probe 成功
dmesg | grep -iE 'video_manager|pwm|probe'
ls /dev/video_manager /sys/class/pwm* 2>/dev/null

# 中断是否真的在计数（PL → PS 中断通路的关键证据）
watch -n1 'cat /proc/interrupts | grep -iE "video|pwm"'
```

**判据**：`/proc/interrupts` 里对应行的计数**在涨**——这是 PL 中断真的接到 PS 的唯一硬证据。

### 3.4 应用层（D6~D8）

```bash
# IMU（spidev）
ls /dev/spidev*
# 用 spidev_test 或自写程序读 CHIP_ID：加速度 0x1E / 陀螺 0x0F

# 视频链路
gst-launch-1.0 v4l2src device=/dev/video0 num-buffers=10 ! jpegenc ! filesink location=/tmp/t.jpg

# 控制
ls /sys/class/pwm/pwmchip*/ch0_{arr,cmp,en}
```

---

## 我现在能替你做 / 你才能做的

| 验证项 | 谁做 | 状态 |
|---|---|---|
| 构建成功、产物齐全 | 我（SSH） | ✅ 已完成 |
| dtb 节点检查 | 我（SSH） | 可随时做 |
| 驱动 `.ko` 编译验证 | 我（SSH） | 待做（需要先覆盖 meta-user） |
| qemu 启动验证 | 我（SSH） | 可随时做 |
| **烧 SD 卡 + 上电** | 你（Windows） | 需要硬件 |
| **串口登录** | 你（或你接串口后我远程） | 需要硬件 |
| **PL 中断计数** | 板子起来后我能做 | 需要先上板 |
| **设备树节点对齐新 XSA** | 我 | 等新 XSA |

---

## 建议顺序

1. 先跑 **第 1 层**（我 5 分钟出结果）
2. 再跑 **第 2 层** qemu（我 10 分钟出结果）——能提前发现 rootfs 挂载、登录、时钟这类问题
3. 你要是有板子，跑 **第 3.1**；串口通了之后，剩下的 3.2~3.4 我可以在板子上远程做
4. 等 PL 补全 IP → 重新导 XSA → 重建设备树 → 再做 3.3
