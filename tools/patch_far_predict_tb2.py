# -*- coding: utf-8 -*-
"""
patch_far_predict_tb2.py -- 修测试台两处编译错

1) 32'd8'hA5 / 32'd8'h5A 写错了（多了个 32'd8），应为 32'hA5 / 32'h5A
2) function 必须至少有一个 input：给 ur_chk_calc 加一个哑参数，调用处补实参

文件是 GBK，字节级改 + 回读比对。
"""

import os

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
REL = 'sim/tb_armor_vision.v'

with open(os.path.join(ROOT, REL), 'rb') as fh:
    raw = fh.read()
for enc in ('gbk', 'utf-8'):
    try:
        t = raw.decode(enc)
        break
    except UnicodeDecodeError:
        continue
else:
    raise SystemExit('%s 编码未知' % REL)
t = t.replace('\r\n', '\n')

fixes = [
    ("32'd8'hA5", "32'hA5", '帧头0'),
    ("32'd8'h5A", "32'h5A", '帧头1'),
    ("function [7:0] ur_chk_calc;\n    integer ck;\n",
     "function [7:0] ur_chk_calc;\n    input        dmy;      // Verilog 要求函数至少一个输入\n    integer      ck;\n",
     '函数输入'),
    ("{24'd0, ur_chk_calc()}", "{24'd0, ur_chk_calc(1'b0)}", '函数调用'),
]

for old, new, what in fixes:
    if t.count(old) != 1:
        raise SystemExit('%s：匹配 %d 处（应为 1）' % (what, t.count(old)))
    t = t.replace(old, new)
    print('[ok]   %s' % what)

out = t.replace('\n', '\r\n')
with open(os.path.join(ROOT, REL), 'wb') as fh:
    fh.write(out.encode(enc))
with open(os.path.join(ROOT, REL), 'rb') as fh:
    if fh.read().decode(enc) != out:
        raise SystemExit('**** 回读比对失败 ****')
print('=== 测试台修复完成（%s）===' % enc)
