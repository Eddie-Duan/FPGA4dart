# -*- coding: utf-8 -*-
"""
uart_parse.py -- 解析 FPGA 侧 P1 上报的 16 字节结果帧（也可用来下发 P2 参数）

帧格式（定长 16 字节，115200 8N1）：
    0  0xA5                      帧头1
    1  0x5A                      帧头2
    2  flags                     b0=valid  b1=adapt_ok  b2=二值显示模式
    3  cx_hi    4  cx_lo          外框中心 x（10bit，高字节只用低 2 位）
    5  cy_hi    6  cy_lo          外框中心 y
    7  ax_hi    8  ax_lo          瞄准点 x
    9  ay_hi   10  ay_lo          瞄准点 y
    11 w                          外框宽（饱和到 255）
    12 area>>7                    面积粗值（243 对应 31104 像素）
    13 fill_q8                    填充率 x256（圆的理论值约 201）
    14 blob_cnt                   本帧合格团块数
    15 checksum                   byte2..byte14 逐字节异或

用法：
    # 0) 先看看有哪些串口可用（拿这个当依据，别直接猜 COM 号）
    python tools/uart_parse.py --list

    # 1) 接串口实时解析（需要 pyserial：pip install pyserial）
    python tools/uart_parse.py COM7

    # 2) 离线解析一段十六进制（例如从逻辑分析仪 / 串口助手导出的）
    python tools/uart_parse.py --hex "A5 5A 03 01 98 00 F8 01 98 00 C7 7F F5 01 A5"

    # 3) 下发一条参数写命令（P2）：0xAA addr data (addr^data)
    python tools/uart_parse.py COM3 --set 0x07 0x01     # CTRL.b0=1 -> 打开自适应阈值
    python tools/uart_parse.py COM3 --set 0x01 0x28     # TH_G-R = 40

参数地址表见 doc/vision_pipeline.md 第 17 节。
"""

import sys
import time

HDR0, HDR1 = 0xA5, 0x5A
FRAME_LEN = 16


def decode_frame(f):
    """f: 16 字节的 list/bytes。返回 dict；帧头或校验不对返回 None。"""
    if len(f) != FRAME_LEN:
        return None
    if f[0] != HDR0 or f[1] != HDR1:
        return None
    chk = 0
    for i in range(2, 15):
        chk ^= f[i]
    if chk != f[15]:
        return None

    flags = f[2]
    cx = (f[3] << 8) | f[4]
    cy = (f[5] << 8) | f[6]
    ax = (f[7] << 8) | f[8]
    ay = (f[9] << 8) | f[10]
    return {
        'valid':      bool(flags & 0x01),
        'adapt_ok':   bool(flags & 0x02),
        'disp_bin':   bool(flags & 0x04),
        'cx': cx, 'cy': cy, 'ax': ax, 'ay': ay,
        'w': f[11],
        'area': f[12] * 128,          # 低位被截掉了，只是粗值
        'fill_q8': f[13],
        'blob_cnt': f[14],
    }


def fmt(d):
    return ('valid=%-5s adapt=%-5s bin=%-5s | 圆心=(%3d,%3d) 瞄准=(%3d,%3d) '
            'w=%3d area~%-6d fill=%3d cnt=%d'
            % (d['valid'], d['adapt_ok'], d['disp_bin'],
               d['cx'], d['cy'], d['ax'], d['ay'],
               d['w'], d['area'], d['fill_q8'], d['blob_cnt']))


def do_list():
    """列出现在真正可用的串口
    （设备管理器里 Status=Unknown 的那些是「管经插过、现在不在场」的幽灵记录，
      不会出现在这里，所以拿它当依据比直接猜 COM 号靠谱）"""
    try:
        from serial.tools import list_ports
    except ImportError:
        raise SystemExit('需要 pyserial：pip install pyserial')
    ports = list(list_ports.comports())
    if not ports:
        print('[X] 没有发现任何可用串口。依次检查：')
        print('    1) 板子有没有上电（UART 桥要板子供电才会枚举）')
        print('    2) USB 线插的是不是 UART 那个口（不是只插 JTAG/下载口）')
        print('    3) CH340/CH343 驱动装了没（设备管理器 -> 端口，看有没有黄色感叹号）')
        print('    4) 串口是不是被别的程序占着（串口助手 / 另一个终端）')
        return
    print('可用串口：')
    for p in ports:
        print('  %-8s %s' % (p.device, p.description))


def do_hex(s):
    raw = bytes(int(x, 16) for x in s.replace(',', ' ').split())
    n = 0
    for i in range(len(raw) - FRAME_LEN + 1):
        d = decode_frame(raw[i:i + FRAME_LEN])
        if d:
            print('[OK] ' + fmt(d))
            n += 1
    if n == 0:
        print('[X] 没找到校验通过的完整帧（%d 字节）' % len(raw))
    else:
        print('共解析到 %d 帧' % n)


def do_serial(port, baud):
    try:
        import serial
    except ImportError:
        raise SystemExit('需要 pyserial：pip install pyserial')

    ser = serial.Serial(port, baud, timeout=1)
    print('打开 %s @ %d 8N1，等待帧（Ctrl+C 退出）...' % (port, baud))
    print('   提示：把 FPGA 的 uart_txd 接到 USB-UART 的 RXD；GND 共地。')
    buf = bytearray()
    n = 0
    try:
        while True:
            buf += ser.read(64)
            while len(buf) >= FRAME_LEN:
                #  对齐帧头
                if buf[0] != HDR0 or buf[1] != HDR1:
                    buf.pop(0)
                    continue
                d = decode_frame(buf[:FRAME_LEN])
                if d is None:
                    buf.pop(0)          # 校验不过，右移一字节重新同步
                    continue
                del buf[:FRAME_LEN]
                n += 1
                print('[%5d] %s' % (n, fmt(d)))
    except KeyboardInterrupt:
        print('\n共收到 %d 帧' % n)
    finally:
        ser.close()


def do_set(port, baud, addr, data):
    try:
        import serial
    except ImportError:
        raise SystemExit('需要 pyserial：pip install pyserial')
    cmd = bytes([0xAA, addr & 0xFF, data & 0xFF, (addr ^ data) & 0xFF])
    ser = serial.Serial(port, baud, timeout=1)
    ser.write(cmd)
    ser.flush()
    time.sleep(0.05)
    ser.close()
    print('已下发: ' + ' '.join('%02X' % b for b in cmd))


def main():
    a = sys.argv[1:]
    if not a:
        raise SystemExit(__doc__)

    baud = 115200
    if '--baud' in a:
        i = a.index('--baud')
        baud = int(a[i + 1])
        del a[i:i + 2]

    if a[0] == '--list':
        do_list()
    elif a[0] == '--hex':
        do_hex(a[1])
    elif a[0] == '--set':
        if len(a) < 4:
            raise SystemExit('用法: --set <port> <addr> <data>')
        do_set(a[1], baud, int(a[2], 0), int(a[3], 0))
    else:
        do_serial(a[0], baud)


if __name__ == '__main__':
    main()
