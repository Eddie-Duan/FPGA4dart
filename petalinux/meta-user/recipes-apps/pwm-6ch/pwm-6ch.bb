SUMMARY = "Six-channel PWM platform driver (xlnx,pwm-6ch-1.0)"
SECTION = "PETALINUX/apps"
LICENSE = "CLOSED"

SRC_URI = "file://pwm_6ch.c \
           file://Makefile \
          "

S = "${WORKDIR}"

inherit module
