# -*- coding: utf-8 -*-
"""patch_p13_main2.py -- 续做 P13 a/c/d 剩余接线（全 ASCII 锚点，幂等）"""
import io
import os
import re

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
P = os.path.join(ROOT, 'rtl/armor_vision.v')

with open(P, 'rb') as fh:
    raw = fh.read()
t = raw.decode('gbk')
crlf = '\r\n' in t
t = t.replace('\r\n', '\n')

print('--- 现状 ---')
for name, a in [
    ('median 例化', 'median3x3 #('),
    ('syn_on 已插', 'assign syn_on'),
    ('cam_pix 已插', 'assign cam_pix'),
    ('lead_auto 已接', '.lead_auto'),
    ('lead_used 已接', '.lead_used'),
    ('st_page 已插', 'assign st_page'),
]:
    print('  %-16s %d' % (name, t.count(a)))

m = re.search(r'wire\s*\[[^\]]*\]\s*bond_w', t)
print('  bond_w 声明 :', m.group(0) if m else '(未找到)')

steps = []

if t.count('assign syn_on') == 0:
    steps.append((
        'median 例化前插合成靶标 + 像素源',
        "median3x3 #(\n    .WIDTH (IMG_W),\n    .AW    (AW   )\n) u_median (\n",
        "//-------------------------------------------------------\n"
        "// (2c) P13a 合成靶标：UART 0x0F=1 时顶替相机像素（默认关闭，行为与原来完全一致）\n"
        "//-------------------------------------------------------\n"
        "assign syn_on = rf_syn_en[0];\n"
        "\n"
        "syn_target #(\n"
        "    .AW     (AW    ),\n"
        "    .WIDTH  (IMG_W ),\n"
        "    .HEIGHT (IMG_H )\n"
        ") u_syn_target (\n"
        "    .clk    (clk        ),\n"
        "    .rst_n  (rst_n      ),\n"
        "    .vsync  (vsync      ),\n"
        "    .x      (x_v        ),\n"
        "    .y      (y_cnt      ),\n"
        "    .spd_q4 (rf_syn_spd ),\n"
        "    .rad    (rf_syn_r   ),\n"
        "    .pix    (syn_pix    ),\n"
        "    .cx     (syn_cx     )\n"
        ");\n"
        "\n"
        "assign cam_pix = syn_on ? syn_pix : data_v;\n"
        "\n"
        "median3x3 #(\n    .WIDTH (IMG_W),\n    .AW    (AW   )\n) u_median (\n"))

if '.din   (cam_pix),\n    .de_o  (med_de )' not in t:
    steps.append(('median 用 cam_pix',
                  "    .din   (data_v ),\n    .de_o  (med_de ),",
                  "    .din   (cam_pix),\n    .de_o  (med_de ),"))

if 'assign pix_seg = med_on ? med_pix : cam_pix;' not in t:
    steps.append(('pix_seg 用 cam_pix',
                  "assign pix_seg = med_on ? med_pix : data_v;",
                  "assign pix_seg = med_on ? med_pix : cam_pix;"))

if '.din   (cam_pix),\n    .dout  (img_d  )' not in t:
    steps.append(('video_delay 用 cam_pix',
                  "    .din   (data_v ),\n    .dout  (img_d  )",
                  "    .din   (cam_pix),\n    .dout  (img_d  )"))

if '.lead_auto' not in t:
    steps.append(('aim_predict 接 lead_auto',
                  "    .lead_q4   (lead_q4_eff),\n",
                  "    .lead_q4   (lead_q4_eff),\n    .lead_auto (rf_lead_auto[0]),\n"))

if '.lead_used' not in t:
    steps.append(('aim_predict 接 lead_used',
                  "    .moving    (pd_mov    )\n);\n",
                  "    .moving    (pd_mov    ),\n    .lead_used (pd_lead   )\n);\n"))

if t.count('assign st_page') == 0:
    steps.append((
        '状态页选择 wire',
        "assign tacc_clr    = reg_written & rf_tacc[7];",
        "assign tacc_clr    = reg_written & rf_tacc[7];\n"
        "\n"
        "//  P13d 状态页：0 = 正常  1 = 距离(cm)/下坠  2 = 宽度(px)/距离  3 = 速度(px/帧)\n"
        "assign st_page = rf_st_page[1:0];\n"
        "\n"
        "wire [7:0] st_v3 = (st_page == 2'd1) ? bl_dist_cm[7:0] :\n"
        "                   (st_page == 2'd2) ? bond_w[7:0] :\n"
        "                   (st_page == 2'd3) ? ((pd_vx[15]) ? 8'd0 : {1'b0, pd_vx[14:7]}) : th_g;\n"
        "wire [7:0] st_w2 = (st_page == 2'd1) ? bl_drop_px[7:0] :\n"
        "                   (st_page == 2'd2) ? bl_dist_cm[7:0] :\n"
        "                   (st_page == 2'd3) ? bond_w[7:0] : 8'd0;\n"))

if '(st_page == 2\'d0) ? th_g' not in t:
    steps.append((
        'seg_display 状态页 mux',
        "    .th_g       (th_g   ),\n"
        "    .th_gr      (th_gr  ),\n"
        "    .th_gb      (th_gb  ),\n"
        "    .bond_valid (bond_valid ),\n"
        "    .bond_w     (bond_w     ),\n",
        "    .th_g       ((st_page == 2'd0) ? th_g : st_v3),\n"
        "    .th_gr      ((st_page == 2'd0) ? th_gr : st_v3),\n"
        "    .th_gb      ((st_page == 2'd0) ? th_gb : st_v3),\n"
        "    .bond_valid (bond_valid ),\n"
        "    .bond_w     ((st_page == 2'd0) ? bond_w : {st_w2, {(AW-8){1'b0}}, 2'b00}),\n"))

if '(st_page != 2\'d0) ? pd_ok' not in t:
    steps.append((
        'LED 状态页',
        "assign led[0] = ~(sel == 2'd0);\n"
        "assign led[1] = ~(sel == 2'd1);\n"
        "assign led[2] = ~(sel == 2'd2);\n",
        "//  状态页时 LED 改成状态位（不用接串口）：led[0]=预测有效 led[1]=目标在动 led[2]=距离有效\n"
        "assign led[0] = ~((st_page != 2'd0) ? pd_ok  : (sel == 2'd0));\n"
        "assign led[1] = ~((st_page != 2'd0) ? pd_mov : (sel == 2'd1));\n"
        "assign led[2] = ~((st_page != 2'd0) ? bl_ok  : (sel == 2'd2));\n"))

if not steps:
    print('[skip] armor_vision 已全部完成')
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
