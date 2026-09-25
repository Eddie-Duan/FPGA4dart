# -*- coding: utf-8 -*-
"""
patch_p11_build.py -- 收尾：把 ballistic.v 加进两个构建脚本，并修 tb 里 track_ab 的例化

1) sim/run_vision_sim.bat       加 ..\rtl\ballistic.v
2) tools/synth_check_vision.tcl 加 $rtl/ballistic.v
3) sim/tb_armor_vision.v        track_ab 的 GATE 参数没了 -> 改成端口 .gate(10'd96)
   （ballistic 已经用 add_source.py 注册进 .xpr 了）
"""

import os

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)


def patch(rel, pairs, enc_hint=None):
    path = os.path.join(ROOT, rel)
    with open(path, 'rb') as fh:
        raw = fh.read()
    for enc in (enc_hint or 'gbk', 'utf-8'):
        try:
            t = raw.decode(enc)
            break
        except UnicodeDecodeError:
            continue
    else:
        raise SystemExit('%s 编码未知' % rel)
    crlf = '\r\n' in t
    t = t.replace('\r\n', '\n')
    for old, new, what in pairs:
        if t.count(old) != 1:
            raise SystemExit('%s / %s：锚点匹配 %d 处（应为 1）' % (rel, what, t.count(old)))
        t = t.replace(old, new)
    out = t.replace('\n', '\r\n') if crlf else t
    with open(path, 'wb') as fh:
        fh.write(out.encode(enc))
    with open(path, 'rb') as fh:
        if fh.read().decode(enc) != out:
            raise SystemExit('**** %s 回读比对失败 ****' % rel)
    print('[ok]   %-28s %s  %d -> %d bytes' % (rel, enc, len(raw), len(out.encode(enc))))


# 1) 仿真脚本
patch('sim/run_vision_sim.bat', [(
    "  ..\\rtl\\aim_predict.v ^\n",
    "  ..\\rtl\\aim_predict.v ^\n  ..\\rtl\\ballistic.v ^\n",
    'ballistic.v')], enc_hint='utf-8')

# 2) 综合脚本
patch('tools/synth_check_vision.tcl', [(
    "    $rtl/aim_predict.v \\\n",
    "    $rtl/aim_predict.v \\\n    $rtl/ballistic.v \\\n",
    'ballistic.v')], enc_hint='utf-8')

# 3) tb 里 track_ab 的 GATE 参数 -> 端口
patch('sim/tb_armor_vision.v', [
    ("track_ab #(\n"
     "    .AW (10), .WIDTH(800), .HEIGHT(480),\n"
     "    .GATE (96), .HIT_N (2), .LOST_N (6)\n"
     ") u_track_test (\n"
     "    .clk       (clk       ),\n"
     "    .rst_n     (rst_n     ),\n"
     "    .vsync     (ta_vsync  ),\n"
     "    .raw_valid (ta_v_in   ),\n",
     "track_ab #(\n"
     "    .AW (10), .WIDTH(800), .HEIGHT(480),\n"
     "    .HIT_N (2), .LOST_N (6)\n"
     ") u_track_test (\n"
     "    .clk       (clk       ),\n"
     "    .rst_n     (rst_n     ),\n"
     "    .vsync     (ta_vsync  ),\n"
     "    .gate      (10'd96    ),   // 门控半径改成运行时端口了\n"
     "    .raw_valid (ta_v_in   ),\n",
     'track_ab 端口'),
])

print('=== 构建脚本 + tb 例化 收尾完成 ===')
