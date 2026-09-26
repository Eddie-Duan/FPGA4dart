# -*- coding: utf-8 -*-
"""
patch_p13_tb.py -- 主测试台：P13c 让相位 11 的提前量期望值变成「物理值」

原来提前量固定 4.0 帧（LEAD_Q4=64）-> 6px/帧 的运动提前 24px，检查区间 [8,48]。
现在按距离自动算：目标半径 100（w≈199，约 0.71m）-> t_flight≈35ms≈1.06 帧
-> lead_q4 = round(3392.4/199) = 17 -> 提前量 ≈ 6*17/16 ≈ 6px。
所以：检查区间改成 [4,12]，并新增一条对 pd_lead 本身的检查（16~18）。
"""
import os

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
P = os.path.join(ROOT, 'sim/tb_armor_vision.v')

with open(P, 'rb') as fh:
    raw = fh.read()
t = raw.decode('gbk')
crlf = '\r\n' in t
t = t.replace('\r\n', '\n')

old = ('    chk_range("mov_lead_amt",\n'
       '              {22\'b0, u_armor_vision.pd_cx} - {22\'b0, center_x}, 32\'d8, 32\'d48);\n'
       '    chk("mov_ay_inside", (u_armor_vision.pd_ay <= center_y), 32\'d1);\n')
new = ('    //  P13c：提前量改成按距离自动算（w≈199 -> 0.71m -> 35ms -> 1.06 帧 -> lead_q4=17）\n'
       '    chk_range("mov_lead_auto", {24\'d0, u_armor_vision.pd_lead}, 32\'d16, 32\'d18);\n'
       '    chk_range("mov_lead_amt",\n'
       '              {22\'b0, u_armor_vision.pd_cx} - {22\'b0, center_x}, 32\'d4, 32\'d12);\n'
       '    chk("mov_ay_inside", (u_armor_vision.pd_ay <= center_y), 32\'d1);\n')
if t.count(old) != 1:
    raise SystemExit('锚点 %d 处' % t.count(old))
t = t.replace(old, new)
print('[ok]   phase 11：lead 期望值改成物理值 + 新增 mov_lead_auto 检查')

out = t.replace('\n', '\r\n') if crlf else t
with open(P, 'wb') as fh:
    fh.write(out.encode('gbk'))
with open(P, 'rb') as fh:
    if fh.read().decode('gbk') != out:
        raise SystemExit('**** 回读比对失败 ****')
print('[ok]   sim/tb_armor_vision.v  %d -> %d bytes' % (len(raw), len(out.encode('gbk'))))
