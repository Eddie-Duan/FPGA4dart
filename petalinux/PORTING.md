# PetaLinux 迁移工作区（从 dart2026 迁到本工程）

来源：`C:\Users\DUANboyang\Desktop\dart2026_-open-source\dart_-linux`
目标：本工程的 PetaLinux 2020.2 工程（XC7Z010/Z020 + 我们的 XSA）

## 目录

```
petalinux/
├── meta-user/            # 从 dart 原样拷贝的 Yocto 层（21 个文件）
│   ├── conf/             # layer.conf / petalinuxbsp.conf / user-rootfsconfig
│   ├── recipes-apps/     # gpio-demo, peekpoke（示例，可选）
│   └── recipes-bsp/
│       ├── device-tree/  # device-tree.bbappend + system-user.dtsi + pl-custom.dtsi
│       └── u-boot/       # u-boot bbappend + platform-top.h + boot.cmd.*
└── drivers/              # 两个 out-of-tree 内核模块的源码
    ├── video_manager/    # video_manager.c / test_app.c / Makefile
    └── pwm_6ch/          # pwm_6ch.c / Makefile
```

> 注意：只拷了源码（`.c` / `.h` / `Makefile` / `.md`），**没拷** `.ko`、`.o`、`.cmd`、`Module.symvers` 这些编译产物——它们绑定旧内核，必须重编。

## 必须改的地方

### 1. `system-user.dtsi`（285 行，板级节点）

它引用的每一个 phandle 都必须和**新 Vivado BD 里的实例名**对得上，否则 `petalinux-build` 在 DTC 阶段直接报 `undefined node`：

| dtsi 里的引用 | 含义 | 新工程要对齐 |
|---|---|---|
| `&i2c0` + `ov9282@60` | PS I2C0 上的 OV9282（DVP 10bit） | 新板是否仍走 I2C0？地址是否 0x60？ |
| `&amba_pl` → `vcap` + `&axi_vdma_0 1` | 视频捕获接 VDMA 的 S2MM | BD 里 VDMA 实例名必须叫 `axi_vdma_0` |
| `&axi_quad_spi_0` / `&axi_quad_spi_1` | PL 侧 SPI（spidev 占位） | BD 实例名对齐；不用就整段删 |
| `&video_mameger_1` | 自定义 IP 的中断 | 注意原文件里拼写就是 `video_mameger_1`（少个 n），改名会找不到节点 |
| `&axi_gpio_0` | LED | BD 实例名对齐 |
| `&sdhci1` + `&pinctrl0` | SDIO（aic8800 WiFi） | 本工程若不用 WiFi，整段可删 |
| `chosen.bootargs` | `root=/dev/mmcblk0p2` | 分区方案变了必须改 |

`pl-custom.dtsi` 是空的（只有 `/ {};`）——PL 侧节点由 Vivado 生成的 `pl.dtsi` 自动带入，通常不用手写。保留这个空文件是为了让 bbappend 不用改。

### 2. `device-tree.bbappend`

用到了 `petalinux_hsm_bridge.tcl` + `xsct`，这是**旧版 PetaLinux 的硬件描述流程**。2020.2 里 `DT_FILES_PATH`/`HDF_EXT` 这套还能用，但如果新工程是 `--get-hw-description=<XSA>` 生成的，这段 `do_configure_append` 可能需要删掉或改写。**先原样拷进去跑，报错再删。**

### 3. `u-boot` 两个 bbappend + `platform-top.h`

`platform-top.h` 里有 DDR 时序和串口配置，换板子（XC7Z010 vs 7020、DDR 容量）基本都要调。不换板可以原样。

### 4. `drivers/*/Makefile`（**现在就有的硬伤**）

两个 Makefile 都写死了别人的路径：

```make
KDIR=/home/wps/Desktop/dart_linux/dart_linux/application/linux-xlnx-xilinx-v2020.2-compile
```

必须在 VM 里改成自己的，例如：

```make
KDIR=$(shell cd ~/petalinux/2020.2 && echo $PWD)/components/yocto/workspace/sources/linux-xlnx
```

**更好的做法**：不要手工 `make`，给它们各写一个 `recipes-apps/*/*.bb`，让 Yocto 编译——这样 `petalinux-build` 一次就能把 `.ko` 塞进 rootfs。原始工程显然没做（`meta-user/recipes-apps` 里只有 gpio-demo 和 peekpoke），所以这块要补。

### 5. `conf/user-rootfsconfig`

只有 `gpio-demo` / `peekpoke` 两项。若把驱动做成 recipe，要在这里加对应条目，否则 `petalinux-config` 的 rootfs 菜单里看不到。

## 等 PetaLinux 到位后的执行顺序

1. `petalinux-create --type project --template zynq --name dart_7020`
2. `petalinux-config --get-hw-description=<新 XSA 所在目录>`
3. 把本目录 `meta-user/*` 覆盖进 `dart_7020/project-spec/meta-user/`
4. 按上表改 `system-user.dtsi` 的 phandle 和 bootargs
5. 补两个驱动的 recipe（我可以写）
6. `petalinux-config` 里开 `SPIDEV`、`UIO`/DMA 相关选项（按实际需要）
7. `petalinux-build` → 出 `image.ub`
8. `petalinux-package --boot --fsbl ... --fpga ... --u-boot --force` → 出 `BOOT.BIN`
9. 跑完 `petalinux-build -x mrproper` 回收 20–30 GB

## 已补的驱动 recipe（2026-11-09）

原工程的两个驱动是靠手工 `make` 编 `.ko`，Makefile 里 `KDIR` 写死成别人的路径，无法复现。已改成标准 Yocto 模块 recipe：

```
meta-user/recipes-apps/
├── video-manager/
│   ├── video-manager.bb          # inherit module
│   └── files/{video_manager.c, test_app.c, Makefile}
└── pwm-6ch/
    ├── pwm-6ch.bb
    └── files/{pwm_6ch.c, Makefile}
```

- `Makefile` 已改成用 `$(KERNEL_SRC)`（Yocto 注入），不再写死路径
- `LICENSE = "CLOSED"`：规避 GPL 校验和的版本差异，内部驱动用这个最稳
- `user-rootfsconfig` 里已加 `CONFIG_video-manager` / `CONFIG_pwm-6ch`，否则 `petalinux-config` 的 rootfs 菜单看不到

**设备树必须同时补节点**，否则 `.ko` 加载后 probe 不到（驱动靠 of_match 匹配）：

| 驱动 | compatible | 设备树里要有 |
|---|---|---|
| video_manager | `xlnx,video-manager-1.0` | PL 里实例名对应节点（原 dart 用 `video_mameger_1`，注意拼写） |
| pwm_6ch | `xlnx,pwm-6ch-1.0` | PL 里 PWM IP 的节点 |

`test_app.c` 目前只随 recipe 打包源文件，没有编成可执行程序——需要的话加一个 `video-manager-test` 的用户态 recipe（`inherit` 默认即可，直接 `oe_runmake`）。
