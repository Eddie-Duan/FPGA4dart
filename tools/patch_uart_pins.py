# -*- coding: utf-8 -*-
"""
patch_uart_pins.py -- 把 UART 接到板载 USB-UART 的引脚上

引脚来源：`达芬奇开发板IO引脚分配表.xlsx`
    uart_rxd  input   U5   UART 的接收
    uart_txd  output  T6   UART 的发送
（另有 uart2_txd=R19 / uart2_rxd=P19，那是 ATK 模块接口，不用）

做三件事：
  1) rtl/ov5640_lcd.v   顶层端口表加 uart_rxd / uart_txd
  2) rtl/ov5640_lcd.v   把 armor_vision 例化处从「1'b1 / 悬空」改成真接线
  3) prj/.../pin.xdc    加两条 PACKAGE_PIN 约束（LVCMOS33，与板上其它 IO 一致）

安全检查：
  - 如果 pin.xdc 里 U5 / T6 已经被别的端口占用 -> 直接报错退出，不写
  - 可重复执行（已加过会自动跳过）

安全性：GBK 解码 -> 纯 ASCII 锚点替换 -> GBK 编码 -> 回读比对。
用法：python tools/patch_uart_pins.py
"""

import os

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
TOP = os.path.join(ROOT, 'rtl', 'ov5640_lcd.v')
XDC = os.path.join(ROOT, 'prj', 'ov5640_lcd.srcs', 'constrs_1', 'new', 'pin.xdc')

# ---------------------------------------------------------------------------
# 1) 顶层端口表
# ---------------------------------------------------------------------------
PORT_OLD = "    input                 sys_rst_n    ,"
PORT_NEW = """    input                 sys_rst_n    ,
    input                 uart_rxd     ,  //板载 USB-UART 接收（PC -> FPGA）
    output                uart_txd     ,  //板载 USB-UART 发送（FPGA -> PC）"""

# 2) 例化处接线
INST_OLD = """    .uart_rxd   (1'b1             ),
    .uart_txd   (                 )"""
INST_NEW = """    .uart_rxd   (uart_rxd         ),
    .uart_txd   (uart_txd         )"""

# 3) xdc
XDC_OLD = """set_property IOSTANDARD LVCMOS33 [get_ports sys_rst_n]
set_property PACKAGE_PIN U2 [get_ports sys_rst_n]"""
XDC_NEW = """set_property IOSTANDARD LVCMOS33 [get_ports sys_rst_n]
set_property PACKAGE_PIN U2 [get_ports sys_rst_n]

#UART（板载 USB-UART：P1 结果上报 / P2 参数写入）
#  引脚取自《达芬奇开发板IO引脚分配表》：uart_rxd=U5、uart_txd=T6
set_property -dict {PACKAGE_PIN U5 IOSTANDARD LVCMOS33} [get_ports uart_rxd]
set_property -dict {PACKAGE_PIN T6 IOSTANDARD LVCMOS33} [get_ports uart_txd]"""


def edit(path, pairs, skip_tokens, label):
    with open(path, 'rb') as fh:
        raw = fh.read()
    text = raw.decode('gbk')
    crlf = '\r\n' in text
    norm = text.replace('\r\n', '\n')

    if all(t in norm for t in skip_tokens):
        print('[skip] %s 已经处理过' % label)
        return

    for old, new in pairs:
        old = old.replace('\r\n', '\n')
        new = new.replace('\r\n', '\n')
        if norm.count(old) != 1:
            raise SystemExit('%s: 锚点匹配 %d 处（应为 1）:\n%s'
                             % (label, norm.count(old), old[:160]))
        norm = norm.replace(old, new)

    out_text = norm.replace('\n', '\r\n') if crlf else norm
    out = out_text.encode('gbk')
    with open(path, 'wb') as fh:
        fh.write(out)
    with open(path, 'rb') as fh:
        if fh.read().decode('gbk') != out_text:
            raise SystemExit('**** %s 回读比对失败 ****' % label)
    print('[ok]   %s  GBK %d -> %d bytes' % (label, len(raw), len(out)))


def main():
    #  安全检查：U5 / T6 是不是已经被占用
    with open(XDC, 'rb') as fh:
        xdc_txt = fh.read().decode('gbk')
    if 'uart_txd' not in xdc_txt:
        for pin in ('U5', 'T6'):
            if ('PACKAGE_PIN %s ' % pin) in xdc_txt or ('PACKAGE_PIN %s}' % pin) in xdc_txt:
                raise SystemExit('!! 引脚 %s 已被别的端口占用，请先核对 pin.xdc，放弃写入' % pin)
        print('[ok]   U5 / T6 未被占用')

    edit(TOP, [(PORT_OLD, PORT_NEW), (INST_OLD, INST_NEW)],
         ['uart_txd     ,', 'uart_txd   (uart_txd'],
         'rtl/ov5640_lcd.v')
    edit(XDC, [(XDC_OLD, XDC_NEW)], ['uart_txd'], 'prj/.../pin.xdc')
    print('done. 记得重新综合 + 实现，然后在 PC 上跑 tools/uart_parse.py COM3')


if __name__ == '__main__':
    main()
