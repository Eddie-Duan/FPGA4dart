# -*- coding: utf-8 -*-
"""
patch_project.py  --  把 armor_vision 視覺管線接進「正點原子 39_ov5640_lcd」例程

【這是遷移用腳本，本專案已經套用過；重複執行會自動跳過】
用途：當你重新從官方例程（39_ov5640_lcd）複製一份乾淨的工程時，
      執行本腳本就能一鍵接上視覺管線，不用手改。

為什麼要用 Python 而不是直接改檔：
    39 工程的 rtl/*.v 與 pin.xdc 都是 **GBK** 編碼（Vivado 在中文環境預設 ANSI），
    用會寫 UTF-8 的編輯器改動會把原本的中文註解變成亂碼且不可逆。
    本腳本全程以 **位元組（bytes）** 方式處理，只替換/插入 ASCII 或已轉成 GBK 的內容，
    檔案其餘位元組完全不動。

會做的事：
    1. rtl/ov5640_lcd.v
         (a) 在 module 埠列加入 key[3:0] / led[3:0]
         (b) 在既有 wire define 區加入視覺相關 wire
         (c) 把 lcd_rgb_top 的 .data_in(rddata) 改成 .data_in(lcd_data)
         (d) 在 endmodule 前插入 armor_vision 例化
    2. prj/.../constrs_1/new/pin.xdc   追加 key[3:0] / led[3:0] 腳位
    3. prj/ov5640_lcd.xpr              把新 rtl 檔註冊進 sources_1

用法（在專案根目錄）：
    python tools/patch_project.py
"""

import os
import re

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)          # 專案根目錄

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
# 要插入 ov5640_lcd.v 的埠宣告（插在 module 標頭之後）
# ----------------------------------------------------------------------------
PORTS = [
    '    input      [3:0]      key          ,  //按键(低电平有效)',
    '    output     [3:0]      led          ,  //LED指示(低电平点亮)',
]

# ----------------------------------------------------------------------------
# 要加入 wire define 區塊的宣告（插在 total_v_pixel 之後）
#   注意：不能用「先使用後宣告」的方式，否則 Vivado 會報
#         "already implicitly declared" 錯誤。
# ----------------------------------------------------------------------------
WIRES = [
    'wire         rd_vsync                 ;  //帧起始脉冲(LCD场信号)',
    'wire  [15:0] lcd_data                 ;  //视觉处理后送LCD的像素',
    'wire         vision_bond_valid        ;  //侦测到装甲板',
    'wire  [9:0]  vision_cx                ;  //装甲板中心x',
    'wire  [9:0]  vision_cy                ;  //装甲板中心y',
]
WIRE_ANCHOR = 'wire  [12:0] total_v_pixel             ;'

# ----------------------------------------------------------------------------
# 要插在 endmodule 之前的例化區
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
    '    .bond_valid (vision_bond_valid),//侦测结果',
    '    .center_x   (vision_cx        ),',
    '    .center_y   (vision_cy        )',
    ');',
]

# ----------------------------------------------------------------------------
# 要追加到 pin.xdc 的腳位（正點原子達芬奇 XC7A35TFGG484-2）
#   本板：按鍵低電平有效（按下 = 0）、LED 低電平點亮
# ----------------------------------------------------------------------------
XDC_ADD = [
    '',
    '',
    '#---------------------- 按键 key[3:0] ---------------------',
    '# 低电平有效（按下 = 0）',
    '#   key[0] : 红 / 蓝 切换',
    '#   key[1] : 颜色门槛 +8',
    '#   key[2] : 颜色门槛 -8',
    '#   key[3] : 显示模式切换',
    'set_property -dict {PACKAGE_PIN T1 IOSTANDARD LVCMOS33} [get_ports {key[0]}]',
    'set_property -dict {PACKAGE_PIN U1 IOSTANDARD LVCMOS33} [get_ports {key[1]}]',
    'set_property -dict {PACKAGE_PIN W2 IOSTANDARD LVCMOS33} [get_ports {key[2]}]',
    'set_property -dict {PACKAGE_PIN T3 IOSTANDARD LVCMOS33} [get_ports {key[3]}]',
    '',
    '#---------------------- LED led[3:0] ----------------------',
    '# 低电平点亮',
    '#   led[0] : 红色模式    led[1] : 蓝色模式',
    '#   led[2] : 侦测到装甲板 led[3] : 心跳',
    'set_property -dict {PACKAGE_PIN R2 IOSTANDARD LVCMOS33} [get_ports {led[0]}]',
    'set_property -dict {PACKAGE_PIN R3 IOSTANDARD LVCMOS33} [get_ports {led[1]}]',
    'set_property -dict {PACKAGE_PIN V2 IOSTANDARD LVCMOS33} [get_ports {led[2]}]',
    'set_property -dict {PACKAGE_PIN Y2 IOSTANDARD LVCMOS33} [get_ports {led[3]}]',
]


def gbk(s):
    """轉成 GBK bytes，並確認可以還原（避免來源字串本身已損壞）"""
    try:
        b = s.encode('gbk')
        if b.decode('gbk') != s:
            raise ValueError('round-trip mismatch')
        return b
    except Exception as exc:                      # noqa: BLE001
        raise SystemExit('GBK 轉換失敗: %r (%s)' % (s, exc))


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
        print('[skip] rtl/ov5640_lcd.v 已經接過 armor_vision')
        return

    nl = detect_nl(data)
    lines = data.split(nl)

    # (a) 埠宣告
    idx = [i for i, ln in enumerate(lines) if ln.startswith(b'module ov5640_lcd(')]
    if len(idx) != 1:
        raise SystemExit('找不到 module ov5640_lcd( 標頭')
    lines[idx[0] + 1:idx[0] + 1] = [gbk(s) for s in PORTS]
    data = nl.join(lines)

    # (b) wire 宣告
    lines = data.split(nl)
    widx = [i for i, ln in enumerate(lines) if ln.startswith(WIRE_ANCHOR.encode('ascii'))]
    if len(widx) != 1:
        raise SystemExit('找不到 total_v_pixel 宣告行')
    lines[widx[0] + 1:widx[0] + 1] = [gbk(s) for s in WIRES]
    data = nl.join(lines)

    # (c) LCD 像素來源改成視覺處理後
    pat = re.compile(rb'\.data_in\s+\(rddata\s*\)')
    if len(pat.findall(data)) != 1:
        raise SystemExit('找不到 .data_in(rddata) 這個連接')
    data = pat.sub(b'.data_in        (lcd_data   )', data)

    # (d) 例化
    lines = data.split(nl)
    ends = [i for i, ln in enumerate(lines) if ln.strip() == b'endmodule']
    if len(ends) != 1:
        raise SystemExit('endmodule 數量不是 1')
    lines[ends[0]:ends[0]] = [gbk(s) for s in INST]

    write_bin(TOP, nl.join(lines))
    print('[ok]  rtl/ov5640_lcd.v  加入 key/led 埠、視覺 wire 與 armor_vision 例化')


def patch_xdc():
    data = read_bin(XDC)
    if b'key[0]' in data:
        print('[skip] pin.xdc 已經有 key 腳位')
        return
    nl = detect_nl(data)
    out = data.rstrip() + nl + nl.join(gbk(s) for s in XDC_ADD) + nl
    write_bin(XDC, out)
    print('[ok]  pin.xdc      追加 key[3:0] / led[3:0] 腳位')


def patch_xpr():
    data = read_bin(XPR)
    nl = detect_nl(data)

    anchor = b'      <File Path="$PSRCDIR/sources_1/ip/mig_7series_0/mig_a.prj">'
    if data.count(anchor) != 1:
        raise SystemExit('xpr 找不到插入錨點')

    # 只插入尚未註冊的檔案（可重複執行）
    todo = [n for n in NEW_RTL if (b'$PPRDIR/../rtl/' + n.encode('ascii') + b'"') not in data]
    if not todo:
        print('[skip] prj/ov5640_lcd.xpr 已經註冊全部新檔案')
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
    print('[ok]  prj/ov5640_lcd.xpr 註冊 %d 個新 rtl 檔: %s' % (len(todo), ', '.join(todo)))


def check_files_exist():
    missing = [n for n in NEW_RTL if not os.path.isfile(os.path.join(ROOT, 'rtl', n))]
    if missing:
        raise SystemExit('rtl 缺少檔案: %s' % ', '.join(missing))


if __name__ == '__main__':
    print('project : %s' % ROOT)
    check_files_exist()
    patch_top()
    patch_xdc()
    patch_xpr()
    print('done.')
