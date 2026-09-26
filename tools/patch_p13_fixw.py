# -*- coding: utf-8 -*-
"""patch_p13_fixw.py -- 修状态页 mux 的位宽（seg_display.bond_w 是 [10:0]，
   原来写成 12 位 -> 会报 "actual bit length 12 differs from formal bit length 11"，
   正是上次把显示通路整成 X 的那类警告，必须消掉）"""
import os

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
P = os.path.join(ROOT, 'rtl/armor_vision.v')

with open(P, 'rb') as fh:
    raw = fh.read()
t = raw.decode('gbk')
crlf = '\r\n' in t
t = t.replace('\r\n', '\n')

old = "    .bond_w     ((st_page == 2'd0) ? bond_w : {st_w2, {(AW-8){1'b0}}, 2'b00}),\n"
new = ("    .bond_w     ((st_page == 2'd0) ? bond_w : {{(AW-7){1'b0}}, st_w2}),\n"
       "    //  ↑ 必须正好 (AW+1) 位：seg_display 的 bond_w 是 [10:0]，多一位少一位都会 warning\n")
if t.count(old) != 1:
    raise SystemExit('锚点 %d 处' % t.count(old))
t = t.replace(old, new)
print('[ok]   状态页宽度 mux 改成 (AW+1) 位')

out = t.replace('\n', '\r\n') if crlf else t
with open(P, 'wb') as fh:
    fh.write(out.encode('gbk'))
with open(P, 'rb') as fh:
    if fh.read().decode('gbk') != out:
        raise SystemExit('**** 回读比对失败 ****')
print('[ok]   %s  %d -> %d bytes' % ('rtl/armor_vision.v', len(raw), len(out.encode('gbk'))))
