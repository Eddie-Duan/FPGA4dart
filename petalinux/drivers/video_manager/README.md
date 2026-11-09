# Video Manager 驱动程序

这是一个完整的Linux驱动程序，实现了中断处理和应用层通信功能。

## 功能特性

1. 中断处理：当硬件中断发生时，驱动程序会读取寄存器中的上下左右位置信息
2. 应用层通信：通过ioctl接口设置阈值，通过read接口获取位置信息
3. 数据缓冲：使用内核FIFO缓冲区暂存中断中获取的数据

## ioctl命令

- `VM_SET_THRESHOLD`：设置R、G、B三个阈值
- `VM_GET_THRESHOLD`：获取当前的阈值设置
- `VM_GET_POSITION`：获取当前的位置信息

## 使用方法

1. 编译驱动：`make`
2. 编译测试应用：`make test_app`
3. 安装驱动：`make install`
4. 运行测试：`./test_app`
5. 卸载驱动：`make uninstall`

## 文件说明

- `video_manager.c`：驱动程序源代码
- `test_app.c`：测试应用程序
- `Makefile`：编译脚本