SUMMARY = "Video manager platform driver (xlnx,video-manager-1.0)"
SECTION = "PETALINUX/apps"
LICENSE = "CLOSED"

SRC_URI = "file://video_manager.c \
           file://Makefile \
          "

S = "${WORKDIR}"

inherit module

# 源码里 MODULE_LICENSE("GPL")，是内核模块，必须走 module 类编译
