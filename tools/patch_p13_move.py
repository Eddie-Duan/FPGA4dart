# -*- coding: utf-8 -*-
"""patch_p13_move.py -- 把 P13 状态页 wire 块从「tacc_clr 后面」搬到 seg_display 之前

原因：xvlog 要求「先声明后使用」，而 bond_w 在第 589 行才声明（脚本原来把块插在 353 行）。
"""
import os

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
P = os.path.join(ROOT, 'rtl/armor_vision.v')

with open(P, 'rb') as fh:
    raw = fh.read()
t = raw.decode('gbk')
crlf = '\r\n' in t
t = t.replace('\r\n', '\n')

block = ("\n"
         "//  P13d 状态页：0 = 正常  1 = 距离(cm)/下坠  2 = 宽度(px)/距离  3 = 速度(px/帧)\n"
         "assign st_page = rf_st_page[1:0];\n"
         "\n"
         "wire [7:0] st_v3 = (st_page == 2'd1) ? bl_dist_cm[7:0] :\n"
         "                   (st_page == 2'd2) ? bond_w[7:0] :\n"
         "                   (st_page == 2'd3) ? ((pd_vx[15]) ? 8'd0 : {1'b0, pd_vx[14:7]}) : th_g;\n"
         "wire [7:0] st_w2 = (st_page == 2'd1) ? bl_drop_px[7:0] :\n"
         "                   (st_page == 2'd2) ? bl_dist_cm[7:0] :\n"
         "                   (st_page == 2'd3) ? bond_w[7:0] : 8'd0;\n")

if t.count(block) != 1:
    raise SystemExit('状态页块匹配 %d 处' % t.count(block))
t = t.replace(block, '')
print('[ok]   摘出状态页块')

anchor = "seg_display #(\n"
if t.count(anchor) != 1:
    raise SystemExit('seg_display 锚点 %d 处' % t.count(anchor))
t = t.replace(anchor, block + "\n" + anchor)
print('[ok]   插到 seg_display 实例之前')

out = t.replace('\n', '\r\n') if crlf else t
with open(P, 'wb') as fh:
    fh.write(out.encode('gbk'))
with open(P, 'rb') as fh:
    if fh.read().decode('gbk') != out:
        raise SystemExit('**** 回读比对失败 ****')
print('[ok]   rtl/armor_vision.v  %d -> %d bytes' % (len(raw), len(out.encode('gbk'))))
