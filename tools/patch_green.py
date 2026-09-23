# -*- coding: utf-8 -*-
"""
patch_green.py  --  把「绿色圆形靶标」这条改动接进官方 39_ov5640_lcd 例程

【为什么用 Python 而不是直接改档】
    39 工程的 rtl/*.v 与 pin.xdc 都是 **GBK** 编码（Vivado 在中文 Windows 下默认 ANSI）。
    用会写 UTF-8 的编辑器改动会把原本的中文注解变成乱码且不可逆。
    本脚本把档案 **以 GBK 解码 -> 在 Unicode 上做替换 -> 再以 GBK 编码写回**，
    写回前会做一次往返比对，不一致就直接报错退出（不会留下坏档）。

会做的事：
    1. rtl/ov5640_lcd.v
         (a) 在 module 埠列加入 seg_sel[5:0] / seg_led[7:0]
         (b) 在 armor_vision 例化里接上这两个埠
         (c) 更新视觉管线的注解
    2. prj/.../constrs_1/new/pin.xdc
         (a) 更新 key / LED 注释为新的按键分工
         (b) 追加 6 位数码管的 seg_sel[5:0] / seg_led[7:0] 引脚
    3. prj/ov5640_lcd.xpr   把 rtl/seg_display.v 注册进 sources_1

用法（在专案根目录）：
    python tools/patch_green.py
"""

import os
import re

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)

TOP = os.path.join(ROOT, 'rtl', 'ov5640_lcd.v')
XDC = os.path.join(ROOT, 'prj', 'ov5640_lcd.srcs', 'constrs_1', 'new', 'pin.xdc')
XPR = os.path.join(ROOT, 'prj', 'ov5640_lcd.xpr')

NEW_RTL = ['seg_display.v']

# ---------------------------------------------------------------------------
# ov5640_lcd.v
# ---------------------------------------------------------------------------
PORT_ANCHOR = '    output     [3:0]      led'
PORT_ADD = [
    '    output     [5:0]      seg_sel      ,  //数码管位选(低电平选通)',
    '    output     [7:0]      seg_led      ,  //数码管段码(低电平点亮)',
]

INST_ANCHOR = '    .led        (led'
INST_ADD = [
    '    .seg_sel    (seg_sel          ),//数码管位选',
    '    .seg_led    (seg_led          ),//数码管段码',
]

VISION_COMMENT_OLD = '颜色分割'
VISION_COMMENT_NEW = '//**  视觉管线：绿色分割 -> 形态学 -> 双投影找绿块 -> 红色圆环/十字 + 数码管'

# ---------------------------------------------------------------------------
# pin.xdc —— 按键 / LED 注释（只改以 # 开头的注释行）
# ---------------------------------------------------------------------------
KEY_COMMENTS = [
    ('key[0]', '#   key[0] : 循环选择要调的阈值（TH_G / TH_G-R / TH_G-B）'),
    ('key[1]', '#   key[1] : 当前选中的阈值 +8'),
    ('key[2]', '#   key[2] : 当前选中的阈值 -8'),
    ('key[3]', '#   key[3] : 显示模式切换（原图变暗+标记 / 纯二值）'),
    ('led[0]', '#   led[0] : 选中 TH_G       led[1] : 选中 TH_G-R'),
    ('led[2]', '#   led[2] : 选中 TH_G-B     led[3] : 检测到目标(常亮)/未检测到(1.5Hz闪)'),
]

SEG_PINS = [
    '#---------------------- 数码管 seg_sel[5:0] / seg_led[7:0] ----------------------',
    '# 板载 6 位共阳数码管：位选低电平选通，段码低电平点亮',
    '#   seg_led[7:0] = {dp,g,f,e,d,c,b,a}',
    'set_property -dict {PACKAGE_PIN J15 IOSTANDARD LVCMOS33} [get_ports {seg_sel[0]}]',
    'set_property -dict {PACKAGE_PIN H17 IOSTANDARD LVCMOS33} [get_ports {seg_sel[1]}]',
    'set_property -dict {PACKAGE_PIN H13 IOSTANDARD LVCMOS33} [get_ports {seg_sel[2]}]',
    'set_property -dict {PACKAGE_PIN G17 IOSTANDARD LVCMOS33} [get_ports {seg_sel[3]}]',
    'set_property -dict {PACKAGE_PIN H18 IOSTANDARD LVCMOS33} [get_ports {seg_sel[4]}]',
    'set_property -dict {PACKAGE_PIN G18 IOSTANDARD LVCMOS33} [get_ports {seg_sel[5]}]',
    'set_property -dict {PACKAGE_PIN H15 IOSTANDARD LVCMOS33} [get_ports {seg_led[0]}]',
    'set_property -dict {PACKAGE_PIN G16 IOSTANDARD LVCMOS33} [get_ports {seg_led[1]}]',
    'set_property -dict {PACKAGE_PIN L13 IOSTANDARD LVCMOS33} [get_ports {seg_led[2]}]',
    'set_property -dict {PACKAGE_PIN G15 IOSTANDARD LVCMOS33} [get_ports {seg_led[3]}]',
    'set_property -dict {PACKAGE_PIN K13 IOSTANDARD LVCMOS33} [get_ports {seg_led[4]}]',
    'set_property -dict {PACKAGE_PIN G13 IOSTANDARD LVCMOS33} [get_ports {seg_led[5]}]',
    'set_property -dict {PACKAGE_PIN H14 IOSTANDARD LVCMOS33} [get_ports {seg_led[6]}]',
    'set_property -dict {PACKAGE_PIN J14 IOSTANDARD LVCMOS33} [get_ports {seg_led[7]}]',
]


def read_bin(path):
    with open(path, 'rb') as fh:
        return fh.read()


def write_bin(path, data):
    with open(path, 'wb') as fh:
        fh.write(data)


def detect_nl(data):
    return b'\r\n' if b'\r\n' in data else b'\n'


def edit_gbk(path, fn, label):
    """以 GBK 读 -> 改 -> 以 GBK 写回，并做往返比对"""
    raw = read_bin(path)
    try:
        text = raw.decode('gbk')
    except UnicodeDecodeError as exc:
        raise SystemExit('**** %s 不是合法的 GBK 档: %s ****' % (path, exc))

    new = fn(text)
    if new == text:
        print('[skip] %s 已经是最新的' % label)
        return

    try:
        out = new.encode('gbk')
    except UnicodeEncodeError as exc:
        raise SystemExit('**** %s 有 GBK 无法表示的符号: %s ****' % (label, exc))

    write_bin(path, out)

    # 回读比对
    back = read_bin(path).decode('gbk')
    if back != new:
        raise SystemExit('**** %s 转换后比对失败，请从 _backup_before_green 还原 ****' % label)
    print('[ok]  %s 已更新 (GBK %d -> %d bytes)' % (label, len(raw), len(out)))


# ---------------------------------------------------------------------------
# 1. rtl/ov5640_lcd.v
# ---------------------------------------------------------------------------
def patch_top():
    def fn(text):
        if 'seg_sel' in text:
            return text

        # (a) 埠列
        i = text.index(PORT_ANCHOR)
        j = text.index('\n', i) + 1
        text = text[:j] + ''.join(p + '\n' for p in PORT_ADD) + text[j:]

        # (b) 例化
        i = text.rindex(INST_ANCHOR)
        j = text.index('\n', i) + 1
        text = text[:j] + ''.join(p + '\n' for p in INST_ADD) + text[j:]

        # (c) 更新视觉管线注解那一行
        lines = text.split('\n')
        for k, line in enumerate(lines):
            if line.lstrip().startswith('//') and VISION_COMMENT_OLD in line:
                lines[k] = VISION_COMMENT_NEW
        return '\n'.join(lines)

    edit_gbk(TOP, fn, 'rtl/ov5640_lcd.v   埠列 + 例化 + 注解')


# ---------------------------------------------------------------------------
# 2. pin.xdc
# ---------------------------------------------------------------------------
def patch_xdc():
    def fn(text):
        nl = '\r\n' if '\r\n' in text else '\n'
        lines = text.split(nl)

        # (a) 注释行（只动以 # 开头的行）
        for k, line in enumerate(lines):
            s = line.strip()
            if not s.startswith('#'):
                continue
            for key, newline in KEY_COMMENTS:
                if key in s:
                    lines[k] = newline
                    break

        text = nl.join(lines)

        # (b) 追加数码管引脚
        if 'seg_sel' not in text:
            text = text.rstrip() + nl + nl + nl.join(SEG_PINS) + nl
        return text

    edit_gbk(XDC, fn, 'prj/.../pin.xdc     注释 + 数码管引脚')


# ---------------------------------------------------------------------------
# 3. prj/ov5640_lcd.xpr
# ---------------------------------------------------------------------------
def patch_xpr():
    data = read_bin(XPR)
    nl = detect_nl(data)

    anchor = b'      <File Path="$PSRCDIR/sources_1/ip/mig_7series_0/mig_a.prj">'
    if data.count(anchor) != 1:
        raise SystemExit('xpr 找不到插入锚点')

    todo = [n for n in NEW_RTL if (b'$PPRDIR/../rtl/' + n.encode('ascii') + b'"') not in data]
    if not todo:
        print('[skip] prj/ov5640_lcd.xpr 已经注册 seg_display.v')
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


if __name__ == '__main__':
    print('project : %s' % ROOT)
    for name in NEW_RTL:
        if not os.path.isfile(os.path.join(ROOT, 'rtl', name)):
            raise SystemExit('rtl 缺少文件: %s' % name)
    patch_top()
    patch_xdc()
    patch_xpr()
    print('done.')
