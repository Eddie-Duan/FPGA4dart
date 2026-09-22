# -*- coding: utf-8 -*-
"""
patch_project.py  --  把 armor_vision 视觉管线接进“正点原子 39_ov5640_lcd”例程

【这是迁移用脚本，本专案已经套用过；重复执行会自动跳过】
用途：当你重新从官方例程（39_ov5640_lcd）复制一份干净的工程时，
      执行本脚本就能一键接上视觉管线，不用手改。

为什么要用 Python 而不是直接改档：
    39 工程的 rtl/*.v 与 pin.xdc 都是 **GBK** 编码（Vivado 在中文环境默认 ANSI），
    用会写 UTF-8 的编辑器改动会把原本的中文注解变成乱码且不可逆。
    本脚本全程以 **字节（bytes）** 方式处理，只替换/插入 ASCII 或已转成 GBK 的内容，
    文件其余字节完全不动。

会做的事：
    1. rtl/ov5640_lcd.v
         (a) 在 module 埠列加入 key[3:0] / led[3:0]
         (b) 在既有 wire define 区加入视觉相关 wire
         (c) 把 lcd_rgb_top 的 .data_in(rddata) 改成 .data_in(lcd_data)
         (d) 在 endmodule 前插入 armor_vision 例化
    2. prj/.../constrs_1/new/pin.xdc   追加 key[3:0] / led[3:0] 引脚
    3. prj/ov5640_lcd.xpr              把新 rtl 档注册进 sources_1

用法（在专案根目录）：
    python tools/patch_project.py
"""

import os
import re

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)          # 专案根目录

TOP  = os.path.join(ROOT, 'rtl', 'ov5640_lcd.v')
XDC  = os.path.join(ROOT, 'prj', 'ov5640_lcd.srcs', 'constrs_1', 'new', 'pin.xdc')
XPR  = os.path.join(ROOT, 'prj', 'ov5640_lcd.xpr')

NEW_RTL = [
    'armor_vision.v',
    'vision_cfg.v',
    'color_seg.v',
    'morph_nxn.v',
    'line_buffer.v',
    'video_delay.v',
    'proj_bond.v',
    'overlay_box.v',
    'key_debounce.v',
]

# ----------------------------------------------------------------------------
# 要插入 ov5640_lcd.v 的埠宣告（插在 module 标头之后）
# ----------------------------------------------------------------------------
PORTS = [
    '    input      [3:0]      key          ,  //按键(低电平有效)',
    '    output     [3:0]      led          ,  //LED指示(低电平点亮)',
]

# ----------------------------------------------------------------------------
# 要加入 wire define 区块的宣告（插在 total_v_pixel 之后）
#   注意：不能用“先使用后宣告”的方式，否则 Vivado 会报
#         "already implicitly declared" 错误。
# ----------------------------------------------------------------------------
WIRES = [
    'wire         rd_vsync                 ;  //帧起始脉冲(LCD场信号)',
    'wire  [15:0] lcd_data                 ;  //视觉处理后送LCD的像素',
    'wire         vision_bond_valid        ;  //检测到装甲板',
    'wire  [9:0]  vision_cx                ;  //装甲板中心x',
    'wire  [9:0]  vision_cy                ;  //装甲板中心y',
]
WIRE_ANCHOR = 'wire  [12:0] total_v_pixel             ;'

# ----------------------------------------------------------------------------
# 要插在 endmodule 之前的例化区
# ----------------------------------------------------------------------------
INST = [
    '',
    '//*****************************************************',
    '//**  视觉处理：颜色分割 -> 形态学 -> 投影 -> 画框/十字',
    '//**  说明文件：README.md / doc/vision_pipeline.md',
    '//*****************************************************',
    '',
    'armor_vision u_armor_vision(',
    '    .clk        (lcd_clk          ),//像素时钟',
    '    .rst_n      (rst_n            ),//复位',
    '    .vsync      (rd_vsync         ),//帧起始脉冲',
    '    .de         (rdata_req        ),//像素有效',
    '    .data_in    (rddata           ),//DDR3读出的像素',
    '    .key        (key              ),//按键',
    '    .data_out   (lcd_data         ),//处理后像素',
    '    .led        (led              ),//LED指示',
    '    .bond_valid (vision_bond_valid),//检测结果',
    '    .center_x   (vision_cx        ),',
    '    .center_y   (vision_cy        )',
    ');',
]

# ----------------------------------------------------------------------------
# 要追加到 pin.xdc 的引脚（正点原子达芬奇 XC7A35TFGG484-2）
#   本板：按键低电平有效（按下 = 0）、LED 低电平点亮
# ----------------------------------------------------------------------------
XDC_ADD = [
    '',
    '',
    '#---------------------- 按键 key[3:0] ---------------------',
    '# 低电平有效（按下 = 0）',
    '#   key[0] : 红 / 蓝 切换',
    '#   key[1] : 颜色阈值 +8',
    '#   key[2] : 颜色阈值 -8',
    '#   key[3] : 显示模式切换',
    'set_property -dict {PACKAGE_PIN T1 IOSTANDARD LVCMOS33} [get_ports {key[0]}]',
    'set_property -dict {PACKAGE_PIN U1 IOSTANDARD LVCMOS33} [get_ports {key[1]}]',
    'set_property -dict {PACKAGE_PIN W2 IOSTANDARD LVCMOS33} [get_ports {key[2]}]',
    'set_property -dict {PACKAGE_PIN T3 IOSTANDARD LVCMOS33} [get_ports {key[3]}]',
    '',
    '#---------------------- LED led[3:0] ----------------------',
    '# 低电平点亮',
    '#   led[0] : 红色模式    led[1] : 蓝色模式',
    '#   led[2] : 检测到装甲板 led[3] : 心跳',
    'set_property -dict {PACKAGE_PIN R2 IOSTANDARD LVCMOS33} [get_ports {led[0]}]',
    'set_property -dict {PACKAGE_PIN R3 IOSTANDARD LVCMOS33} [get_ports {led[1]}]',
    'set_property -dict {PACKAGE_PIN V2 IOSTANDARD LVCMOS33} [get_ports {led[2]}]',
    'set_property -dict {PACKAGE_PIN Y2 IOSTANDARD LVCMOS33} [get_ports {led[3]}]',
]


def gbk(s):
    """转成 GBK bytes，并确认可以还原（避免来源字串本身已损坏）"""
    try:
        b = s.encode('gbk')
        if b.decode('gbk') != s:
            raise ValueError('round-trip mismatch')
        return b
    except Exception as exc:                      # noqa: BLE001
        raise SystemExit('GBK 转换失败: %r (%s)' % (s, exc))


def read_bin(path):
    with open(path, 'rb') as fh:
        return fh.read()


def write_bin(path, data):
    with open(path, 'wb') as fh:
        fh.write(data)


def detect_nl(data):
    return b'\r\n' if b'\r\n' in data else b'\n'


def patch_top():
    data = read_bin(TOP)
    if b'u_armor_vision' in data:
        print('[skip] rtl/ov5640_lcd.v 已经接过 armor_vision')
        return

    nl = detect_nl(data)
    lines = data.split(nl)

    # (a) 埠宣告
    idx = [i for i, ln in enumerate(lines) if ln.startswith(b'module ov5640_lcd(')]
    if len(idx) != 1:
        raise SystemExit('找不到 module ov5640_lcd( 标头')
    lines[idx[0] + 1:idx[0] + 1] = [gbk(s) for s in PORTS]
    data = nl.join(lines)

    # (b) wire 宣告
    lines = data.split(nl)
    widx = [i for i, ln in enumerate(lines) if ln.startswith(WIRE_ANCHOR.encode('ascii'))]
    if len(widx) != 1:
        raise SystemExit('找不到 total_v_pixel 宣告行')
    lines[widx[0] + 1:widx[0] + 1] = [gbk(s) for s in WIRES]
    data = nl.join(lines)

    # (c) LCD 像素来源改成视觉处理后
    pat = re.compile(rb'\.data_in\s+\(rddata\s*\)')
    if len(pat.findall(data)) != 1:
        raise SystemExit('找不到 .data_in(rddata) 这个连接')
    data = pat.sub(b'.data_in        (lcd_data   )', data)

    # (d) 例化
    lines = data.split(nl)
    ends = [i for i, ln in enumerate(lines) if ln.strip() == b'endmodule']
    if len(ends) != 1:
        raise SystemExit('endmodule 数量不是 1')
    lines[ends[0]:ends[0]] = [gbk(s) for s in INST]

    write_bin(TOP, nl.join(lines))
    print('[ok]  rtl/ov5640_lcd.v  加入 key/led 埠、视觉 wire 与 armor_vision 例化')


def patch_xdc():
    data = read_bin(XDC)
    if b'key[0]' in data:
        print('[skip] pin.xdc 已经有 key 引脚')
        return
    nl = detect_nl(data)
    out = data.rstrip() + nl + nl.join(gbk(s) for s in XDC_ADD) + nl
    write_bin(XDC, out)
    print('[ok]  pin.xdc      追加 key[3:0] / led[3:0] 引脚')


def patch_xpr():
    data = read_bin(XPR)
    nl = detect_nl(data)

    anchor = b'      <File Path="$PSRCDIR/sources_1/ip/mig_7series_0/mig_a.prj">'
    if data.count(anchor) != 1:
        raise SystemExit('xpr 找不到插入锚点')

    # 只插入尚未注册的文件（可重复执行）
    todo = [n for n in NEW_RTL if (b'$PPRDIR/../rtl/' + n.encode('ascii') + b'"') not in data]
    if not todo:
        print('[skip] prj/ov5640_lcd.xpr 已经注册全部新文件')
        return

    blocks = b''
    for name in todo:
        blocks += (b'      <File Path="$PPRDIR/../rtl/' + name.encode('ascii') + b'">' + nl +
                   b'        <FileInfo>' + nl +
                   b'          <Attr Name="UsedIn" Val="synthesis"/>' + nl +
                   b'          <Attr Name="UsedIn" Val="implementation"/>' + nl +
                   b'          <Attr Name="UsedIn" Val="simulation"/>' + nl +
                   b'        </FileInfo>' + nl +
                   b'      </File>' + nl)

    write_bin(XPR, data.replace(anchor, blocks + anchor))
    print('[ok]  prj/ov5640_lcd.xpr 注册 %d 个新 rtl 档: %s' % (len(todo), ', '.join(todo)))


def check_files_exist():
    missing = [n for n in NEW_RTL if not os.path.isfile(os.path.join(ROOT, 'rtl', n))]
    if missing:
        raise SystemExit('rtl 缺少文件: %s' % ', '.join(missing))


if __name__ == '__main__':
    print('project : %s' % ROOT)
    check_files_exist()
    patch_top()
    patch_xdc()
    patch_xpr()
    print('done.')
