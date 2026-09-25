# -*- coding: utf-8 -*-
"""
patch_p11_av.py -- armor_vision.v 接线：弹道补偿模块 + 三个运行时参数 + 死寄存器

1) 例化 ballistic，并把它接到 result_frame（dist_cm / drop_px / fx / fy）
2) overlay_box 的圆环宽度 / track_ab 的门控半径 / chroma_hist 的前景占比
   改成「写过 UART 寄存器就用寄存器值，否则用 parameter 默认」
3) LCD 上的黄色十字改成 fx/fy（= 预测 + 几何偏移 + 下坠补偿后的最终瞄准点）
4) reg_file 新增 0x0B = DROP_SCALE
5) 给新的关键信号打 mark_debug（Vivado 里 Set Up Debug 一眼能挂上）

GBK 字节级改 + 回读比对。
"""

import os
import re

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
REL = 'rtl/armor_vision.v'


def load(rel):
    with open(os.path.join(ROOT, rel), 'rb') as fh:
        raw = fh.read()
    for enc in ('gbk', 'utf-8'):
        try:
            return len(raw), raw.decode(enc).replace('\r\n', '\n'), enc, ('\r\n' in raw.decode(enc))
        except UnicodeDecodeError:
            continue
    raise SystemExit('%s 编码未知' % rel)


def save(rel, text, enc, crlf, old_len):
    out = text.replace('\n', '\r\n') if crlf else text
    data = out.encode(enc)
    with open(os.path.join(ROOT, rel), 'wb') as fh:
        fh.write(data)
    with open(os.path.join(ROOT, rel), 'rb') as fh:
        if fh.read().decode(enc) != out:
            raise SystemExit('**** %s 回读比对失败 ****' % rel)
    print('[ok]   %-24s %s  %d -> %d bytes' % (rel, enc, old_len, len(data)))


def sub(t, old, new, what):
    if t.count(old) != 1:
        raise SystemExit('%s：锚点匹配 %d 处（应为 1）' % (what, t.count(old)))
    return t.replace(old, new)


def resub(t, pat, new, what):
    nt, n = re.subn(pat, new, t, count=1, flags=re.S)
    if n != 1:
        raise SystemExit('%s：锚点匹配 %d 处（应为 1）' % (what, n))
    return nt


raw, t, enc, crlf = load(REL)
if 'u_ballistic' in t:
    print('[skip] %s 已打过补丁' % REL)
    raise SystemExit(0)

#--------------------------------------------------------------------------
# 1) 参数
#--------------------------------------------------------------------------
t = resub(t, r"( *parameter \[7:0\] LEAD_Q4_DEF = 8'd64,[^\n]*\n)",
          r"\1"
          "    parameter DIST_EN         = 1'b1  ,   // 弹道补偿（距离 + 下坠）总开关\n"
          "    parameter [7:0] DROP_SCALE_DEF = 8'd255,   // Q8 弹速修正：255 = 基准 20m/s\n",
          '参数')

#--------------------------------------------------------------------------
# 2) wire 声明
#--------------------------------------------------------------------------
t = sub(t,
        "wire [7:0]    rf_lead_q4 ;\n",
        "wire [7:0]    rf_lead_q4 ;\n"
        "wire [7:0]    rf_drop_sc ;   // 0x0B 弹速修正\n",
        'rf_drop_sc')
t = sub(t,
        "wire          draw_p          ;   // 预测十字（黄色）\n",
        "wire          draw_p          ;   // 预测十字（黄色）\n"
        "\n"
        "//  ---- P11 弹道补偿（新增）----\n"
        "wire [15:0]   bl_dist_cm, bl_drop_px;\n"
        "wire [AW-1:0] bl_fx, bl_fy   ;\n"
        "wire          bl_ok          ;   // 距离有效\n"
        "wire [7:0]    ring_t_eff     ;   // 0x06\n"
        "wire [7:0]    gate_eff       ;   // 0x08\n"
        "wire [7:0]    pct_eff        ;   // 0x09\n"
        "wire [7:0]    drop_sc_eff    ;   // 0x0B\n",
        'P11 wires')

#--------------------------------------------------------------------------
# 3) reg_file 例化 + 生效值
#--------------------------------------------------------------------------
t = sub(t,
        "    .r_lead_q4  (rf_lead_q4 ),\n",
        "    .r_lead_q4  (rf_lead_q4 ),\n"
        "    .r_drop_sc  (rf_drop_sc ),\n",
        'reg_file 例化')

t = sub(t,
        "wire pred_on  = PRED_EN  | rf_ctrl[5];   // b5 = 速度预测使能\n",
        "wire pred_on  = PRED_EN  | rf_ctrl[5];   // b5 = 速度预测使能\n"
        "wire dist_on  = DIST_EN  | rf_ctrl[6];   // b6 = 弹道补偿使能\n",
        'dist_on')

t = sub(t,
        "assign lead_q4_eff     = reg_written ? rf_lead_q4 : LEAD_Q4_DEF;\n",
        "assign lead_q4_eff     = reg_written ? rf_lead_q4 : LEAD_Q4_DEF;\n"
        "//  下面三条就是以前「文档写了、代码没接」的死寄存器（0x06/0x08/0x09），现在真接上了\n"
        "wire [7:0]    ring_t_eff = reg_written ? rf_ring_t : RING_T[7:0];\n"
        "wire [7:0]    gate_eff   = reg_written ? rf_gate   : GATE[7:0];\n"
        "wire [7:0]    pct_eff    = reg_written ? rf_pct    : ADAPT_PCT[7:0];\n"
        "wire [7:0]    drop_sc_eff= reg_written ? rf_drop_sc        : DROP_SCALE_DEF;\n",
        '生效值')

#--------------------------------------------------------------------------
# 4) 三个子模块接上运行时端口
#--------------------------------------------------------------------------
t = sub(t,
        "chroma_hist #(\n"
        "    .PCT       (ADAPT_PCT),\n"
        "    .MIN_TOTAL (2000     )\n"
        ") u_chroma_hist (\n",
        "chroma_hist #(\n"
        "    .MIN_TOTAL (2000     )\n"
        ") u_chroma_hist (\n",
        'chroma_hist 去参数')
t = sub(t,
        "    .b8        ({pix_seg[4:0],   3'b0}),\n"
        "    .en        (adapt_on   ),\n",
        "    .b8        ({pix_seg[4:0],   3'b0}),\n"
        "    .pct       (pct_eff    ),\n"
        "    .en        (adapt_on   ),\n",
        'chroma_hist 接端口')

t = sub(t,
        "track_ab #(\n"
        "    .AW     (AW    ),\n"
        "    .WIDTH  (IMG_W ),\n"
        "    .HEIGHT (IMG_H ),\n"
        "    .GATE   (GATE  ),\n"
        "    .HIT_N  (HIT_N ),\n"
        "    .LOST_N (LOST_N)\n"
        ") u_track_ab (\n"
        "    .clk       (clk       ),\n"
        "    .rst_n     (rst_n     ),\n"
        "    .vsync     (vsync     ),\n",
        "track_ab #(\n"
        "    .AW     (AW    ),\n"
        "    .WIDTH  (IMG_W ),\n"
        "    .HEIGHT (IMG_H ),\n"
        "    .HIT_N  (HIT_N ),\n"
        "    .LOST_N (LOST_N)\n"
        ") u_track_ab (\n"
        "    .clk       (clk       ),\n"
        "    .rst_n     (rst_n     ),\n"
        "    .vsync     (vsync     ),\n"
        "    .gate      (gate_eff  ),\n",
        'track_ab 接端口')

t = sub(t,
        "overlay_box #(\n"
        "    .AW      (AW     ),\n"
        "    .RING_T  (RING_T ),\n"
        "    .CROSS_L (CROSS_L)\n"
        ") u_overlay_box (\n",
        "overlay_box #(\n"
        "    .AW      (AW     ),\n"
        "    .CROSS_L (CROSS_L)\n"
        ") u_overlay_box (\n",
        'overlay_box 去参数')

#--------------------------------------------------------------------------
# 5) 弹道模块例化（放在 aim_predict 之后）
#--------------------------------------------------------------------------
t = sub(t,
        "    .moving    (pd_mov    )\n"
        ");\n",
        "    .moving    (pd_mov    )\n"
        ");\n"
        "\n"
        "//-------------------------------------------------------\n"
        "// (9c) 弹道补偿（P11）：距离反推 + 下坠补偿 -> 最终建议瞄准点 fx/fy\n"
        "//   两张 1/w 查表搞定（推导见 rtl/ballistic.v 顶部），零除法、时序零风险。\n"
        "//   弹速不同就写 UART 0x0B 的 DROP_SCALE，不用重新综合。\n"
        "//-------------------------------------------------------\n"
        "ballistic #(\n"
        "    .AW     (AW    ),\n"
        "    .WIDTH  (IMG_W ),\n"
        "    .HEIGHT (IMG_H )\n"
        ") u_ballistic (\n"
        "    .clk        (clk        ),\n"
        "    .rst_n      (rst_n      ),\n"
        "    .vsync      (vsync      ),\n"
        "    .en         (dist_on    ),\n"
        "    .raw_valid  (raw_valid  ),\n"
        "    .bw         (bond_w     ),\n"
        "    .aim_h_q8   (aim_h_eff  ),\n"
        "    .pcx        (pd_cx      ),\n"
        "    .pcy        (pd_cy      ),\n"
        "    .drop_scale (drop_sc_eff),\n"
        "    .dist_cm    (bl_dist_cm ),\n"
        "    .drop_px    (bl_drop_px ),\n"
        "    .fx         (bl_fx      ),\n"
        "    .fy         (bl_fy      ),\n"
        "    .dist_ok    (bl_ok      )\n"
        ");\n",
        'ballistic 例化')

#--------------------------------------------------------------------------
# 6) overlay 的预测十字改成最终瞄准点（含下坠补偿）
#--------------------------------------------------------------------------
t = sub(t,
        "    .pvx   (pd_cx     ),   // 预测瞄准点（黄色十字，只在目标在动时画）\n"
        "    .pvy   (pd_ay     ),\n",
        "    .pvx   (bl_fx     ),   // 最终瞄准点（黄色十字，只在目标在动时画）\n"
        "    .pvy   (bl_fy     ),   //   = 预测灯心 + 几何偏移 + 下坠补偿\n"
        "    .ring_t(ring_t_eff),\n",
        'overlay 预测十字')

#--------------------------------------------------------------------------
# 7) result_frame 接上新字段
#--------------------------------------------------------------------------
t = sub(t,
        "    .px         (pd_cx      ),\n"
        "    .py         (pd_cy      ),\n",
        "    .px         (pd_cx      ),\n"
        "    .py         (pd_cy      ),\n"
        "    .dist_ok    (bl_ok      ),\n"
        "    .dist_cm    (bl_dist_cm ),\n"
        "    .drop_px    (bl_drop_px ),\n"
        "    .fx         (bl_fx      ),\n"
        "    .fy         (bl_fy      ),\n",
        'result_frame 新字段')

#--------------------------------------------------------------------------
# 8) mark_debug：新关键信号挂出来，Vivado 里一眼能 Set Up Debug
#--------------------------------------------------------------------------
t = sub(t,
        "wire [AW-1:0] bl_fx, bl_fy   ;\n",
        "(* mark_debug = \"true\" *) wire [AW-1:0] bl_fx, bl_fy;   // 最终瞄准点（ILA 重点）\n",
        'mark_debug fx/fy')
t = sub(t,
        "wire [15:0]   bl_dist_cm, bl_drop_px;\n",
        "(* mark_debug = \"true\" *) wire [15:0] bl_dist_cm, bl_drop_px;  // 距离 / 下坠\n",
        'mark_debug dist')
t = sub(t,
        "wire signed [15:0] pd_vx, pd_vy   ;  // 速度估计 Q4\n",
        "(* mark_debug = \"true\" *) wire signed [15:0] pd_vx, pd_vy;  // 速度估计 Q4\n",
        'mark_debug 速度')

save(REL, t, enc, crlf, raw)
print('=== armor_vision 接线完成 ===')

#==========================================================================
# 9) reg_file.v：新增 0x0B = DROP_SCALE（软速修正，Q8）
#==========================================================================
REL2 = 'rtl/reg_file.v'
raw2, t2, enc2, crlf2 = load(REL2)
if 'r_drop_sc' in t2:
    print('[skip] %s 已打过补丁' % REL2)
else:
    t2 = sub(t2, "    output reg [7:0]   r_lead_q4 ,",
             "    output reg [7:0]   r_lead_q4 ,\n"
             "    output reg [7:0]   r_drop_sc ,   // 0x0B 弹速修正（Q8，255 = 20m/s）",
             'reg_file 端口')
    t2 = sub(t2, "        r_lead_q4  <= 8'd64;",
             "        r_lead_q4  <= 8'd64;\n"
             "        r_drop_sc  <= 8'd255;",
             'reg_file 默认值')
    t2 = sub(t2, "                                8'h0A: r_lead_q4  <= data_t;",
             "                                8'h0A: r_lead_q4  <= data_t;\n"
             "                                8'h0B: r_drop_sc  <= data_t;",
             'reg_file 地址')
    save(REL2, t2, enc2, crlf2, raw2)
print('=== 全部完成 ===')
