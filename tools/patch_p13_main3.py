# -*- coding: utf-8 -*-
"""patch_p13_main3.py -- 补上 P13 的 wire 声明与 reg_file 端口连接
（前一个脚本在第三步报锚点错而中止，save() 在最后，所以这两步没落盘）"""
import os

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
P = os.path.join(ROOT, 'rtl/armor_vision.v')

with open(P, 'rb') as fh:
    raw = fh.read()
t = raw.decode('gbk')
crlf = '\r\n' in t
t = t.replace('\r\n', '\n')

steps = []

if t.count('rf_syn_spd, rf_syn_r') == 0:
    steps.append((
        'P13 新 wire',
        "wire          mask_t, de_t   ;   // 累积后的掩码（与 x_t/y_t 对齐）\n",
        "wire          mask_t, de_t   ;   // 累积后的掩码（与 x_t/y_t 对齐）\n"
        "\n"
        "//  ---- P13 ----\n"
        "wire [7:0]    rf_syn_spd, rf_syn_r, rf_syn_en, rf_st_page, rf_lead_auto;\n"
        "wire          syn_on   ;\n"
        "wire [15:0]   syn_pix  ;\n"
        "wire [15:0]   cam_pix  ;   // 真正进管线的像素（相机 or 合成）\n"
        "wire [AW-1:0] syn_cx   ;\n"
        "wire [1:0]    st_page  ;\n"
        "wire [7:0]    pd_lead  ;   // 实际使用的提前量（ILA/仿真观测）\n"))

if t.count('.r_syn_spd') == 0:
    steps.append((
        'reg_file 新端口',
        "    .r_tacc     (rf_tacc    ),\n",
        "    .r_tacc     (rf_tacc    ),\n"
        "    .r_syn_spd  (rf_syn_spd ),\n"
        "    .r_syn_r    (rf_syn_r   ),\n"
        "    .r_syn_en   (rf_syn_en  ),\n"
        "    .r_st_page  (rf_st_page ),\n"
        "    .r_lead_auto(rf_lead_auto),\n"))

if not steps:
    print('[skip] 已补过')
else:
    for what, old, new in steps:
        n = t.count(old)
        if n != 1:
            raise SystemExit('%s：锚点 %d 处' % (what, n))
        t = t.replace(old, new)
        print('[ok]   %s' % what)
    out = t.replace('\n', '\r\n') if crlf else t
    with open(P, 'wb') as fh:
        fh.write(out.encode('gbk'))
    with open(P, 'rb') as fh:
        if fh.read().decode('gbk') != out:
            raise SystemExit('**** 回读比对失败 ****')
    print('[ok]   rtl/armor_vision.v  %d -> %d bytes' % (len(raw), len(out.encode('gbk'))))
