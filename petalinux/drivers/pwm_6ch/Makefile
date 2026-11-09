ARCH=arm
CROSS_COMPILE=arm-xilinx-linux-gnueabi-
KDIR=/home/wps/Desktop/dart_linux/dart_linux/application/linux-xlnx-xilinx-v2020.2-compile
PWD:=$(shell pwd)

obj-m:= pwm_6ch.o

all:
	$(MAKE) -C $(KDIR) M=$(PWD) ARCH=$(ARCH) CROSS_COMPILE=$(CROSS_COMPILE) modules
