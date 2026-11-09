ARCH=arm
CROSS_COMPILE=arm-xilinx-linux-gnueabi-
KDIR=/home/wps/Desktop/dart_linux/dart_linux/application/linux-xlnx-xilinx-v2020.2-compile
PWD:=$(shell pwd)

obj-m:= video_manager.o

all: modules test

modules: video_manager.c
	$(MAKE) -C $(KDIR) M=$(PWD) ARCH=$(ARCH) CROSS_COMPILE=$(CROSS_COMPILE) modules

test: test_app.c
	$(CC) test_app.c -o vm_test

clean:
	rm video_manager.ko
	rm vm_test
	rm video_manager.o
	rm video_manager.mod.c
	rm video_manager.mod.o
