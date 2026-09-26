# -*- coding: utf-8 -*-
"""patch_p13_tbfix.py -- tb_p13.v 适配 row_t（行级预算寄存器）的契约：换行/改半径后要过时钟

（上一个脚本用 ascii 读 tb_p13.v 失败了——它里面有中文注释，必须 utf-8。）
"""
import os

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
P = os.path.join(ROOT, 'sim/tb_p13.v')

with open(P, 'rb') as fh:
    raw = fh.read()
t = raw.decode('utf-8')
crlf = '\r\n' in t
t = t.replace('\r\n', '\n')

pairs = [
    # 起点：settle 之后再量
    ("        sy_x = 10'd400; sy_y = 10'd240; #1;\n",
     "        sy_x = 10'd400; sy_y = 10'd240;\n"
     "        repeat(3) @(posedge clk);          // row_t 是行级预算寄存器，要先跟上这一行\n"),
    # 换到 y=302：等 row_t 跟上再读
    ("        sy_y = 10'd302; sy_x = 10'd400; #1;     // |302-240| = 62 > 60 -> 圆外\n",
     "        sy_y = 10'd302; sy_x = 10'd400;         // |302-240| = 62 > 60 -> 圆外\n"
     "        repeat(3) @(posedge clk);               // 换行后 row_t 要一个时钟才跟上\n"),
    ("        sy_y = 10'd240; #1;\n",
     "        sy_y = 10'd240; repeat(3) @(posedge clk);\n"),
    # 改半径：r2 跟 row_t 都要重新算
    ("        sy_rad = 10'd100; sy_x = 10'd500; #1;\n",
     "        sy_rad = 10'd100; sy_x = 10'd500; repeat(3) @(posedge clk);\n"),
]
for old, new in pairs:
    if t.count(old) != 1:
        raise SystemExit('tb 锚点 %d 处: %r' % (t.count(old), old[:48]))
    t = t.replace(old, new)
    print('[ok]   %s' % old.strip()[:52])

out = t.replace('\n', '\r\n') if crlf else t
with open(P, 'wb') as fh:
    fh.write(out.encode('utf-8'))
with open(P, 'rb') as fh:
    if fh.read().decode('utf-8') != out:
        raise SystemExit('**** 回读比对失败 ****')
print('[ok]   sim/tb_p13.v  %d -> %d bytes' % (len(raw), len(out.encode('utf-8'))))
