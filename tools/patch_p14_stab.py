# -*- coding: utf-8 -*-
"""
patch_p14_stab.py -- 治「斜置屏幕时绿块范围乱跳 -> 黄十字乱闪」+「远灯判定不了」

诊断链（三个症状其实是一条因果链）：
  反光/AWB 随角度变化 -> color_seg 边界抖动 -> 形态学腐蚀后的框每帧变很多像素
  -> w 抖 -> 瞄准偏移(1.449w) / 距离(14135/w) / 下坠(4454.5/w) 全跟着抖
  -> aim_predict 看到 cx/cy 帧间跳动(|v|>=1px/帧) -> pd_mov=1 -> 黄十字乱闪
  -> fx/fy 报给云台的值也在抖

修法（都不用新文件，避免再踩 .xpr 注册坑）：
1) blob_track：选中团块的**外框做 3 帧中值**（对 sl/sr/st/sb 各一次），
   再从中值框导出 cx/cy/bw/aim_y。中值只干掉单帧离群值、对恒定/匀速目标几乎无延迟
   （比 IIR 安全：IIR 会给运动目标带来固定滞后，把相位 11 的提前量测试搞歪）。
   第一个有效帧直接「装载历史」（中值=当帧值），所以静态场景与改动前逐位一致；
   目标丢失时清历史，重新捕获后同样先装载。
2) blob_track：宽松档对**极小团块（面积 <= 32）跳过长宽比/填充率检查**
   —— 那个尺寸下量化误差主导，检查只会把远灯误杀。这就是「远灯只高亮不判定」的根因。
3) aim_predict：MOVE_Q4 默认 16(1px/帧) -> 32(2px/帧)，别再被 ±1px 抖动触发黄十字。
4) 新增 0x12 flags2：bit0 = 强制打开 α-β 跟踪器 track_ab（默认仍按 TRK_EN=0），
   方便在板上 A/B 对比「带门控+滤波」与「不带」的差别。

关于 PID/EKF：PID 是控制器（属于下游云台环路），不解决「测量抖动」；
EKF 在 RTL 里是浮点/矩阵运算，代价高，而且它修不了「尺寸测量本身带系统性波动」。
这里正确的工具箱是：中值（去离群）+ α-β（平滑/测速，也就是我们已有的 track_ab）+
迟滞/持久性（HIT_N/LOST_N、MOVE_Q4）。
"""
import os

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def load(rel, enc='gbk'):
    with open(os.path.join(ROOT, rel), 'rb') as fh:
        raw = fh.read()
    t = raw.decode(enc)
    return raw, t, ('\r\n' in t), enc


def save(rel, raw, t, crlf, enc='gbk'):
    out = t.replace('\n', '\r\n') if crlf else t
    with open(os.path.join(ROOT, rel), 'wb') as fh:
        fh.write(out.encode(enc))
    with open(os.path.join(ROOT, rel), 'rb') as fh:
        if fh.read().decode(enc) != out:
            raise SystemExit('**** %s 回读比对失败 ****' % rel)
    print('[ok]   %s  %d -> %d bytes' % (rel, len(raw), len(out.encode(enc))))


def sub(t, old, new, what):
    if t.count(old) != 1:
        raise SystemExit('%s：锚点 %d 处（应为 1）' % (what, t.count(old)))
    print('[ok]   %s' % what)
    return t.replace(old, new)


# =====================================================================
# 1) blob_track.v —— 中值3 稳定外框 + 小目标免形状检查
# =====================================================================
rel = 'rtl/blob_track.v'
raw, t, crlf, enc = load(rel)
t = t.replace('\r\n', '\n')

# 1a) 中值函数（放在 cx_w 那一段之前）
t = sub(t, "wire [AW:0]   cx_w = ({1'b0, sl_r} + {1'b0, sr_r}) >> 1;\n",
        "//  ---- P14 外框 3 帧中值：干掉单帧离群值（斜置屏幕反光/AWB 抖动）----\n"
        "//  用中值而不是 IIR：中值对恒定/匀速目标几乎没有滞后，IIR 会给运动目标带来固定滞后。\n"
        "function [AW:0] med3;\n"
        "    input [AW:0] a, b, c;\n"
        "    begin\n"
        "        med3 = (a > b) ? ((b > c) ? b : ((a > c) ? c : a))\n"
        "                       : ((a > c) ? a : ((b > c) ? c : b));\n"
        "    end\n"
        "endfunction\n"
        "\n"
        "reg  [AW:0] hl1, hl2, hr1, hr2, ht1, ht2, hb1, hb2;\n"
        "reg         have_hist;\n"
        "wire [AW:0] sl_f = have_hist ? med3({1'b0, sl_r}, hl1, hl2) : {1'b0, sl_r};\n"
        "wire [AW:0] sr_f = have_hist ? med3({1'b0, sr_r}, hr1, hr2) : {1'b0, sr_r};\n"
        "wire [AW:0] st_f = have_hist ? med3({1'b0, st_r}, ht1, ht2) : {1'b0, st_r};\n"
        "wire [AW:0] sb_f = have_hist ? med3({1'b0, sb_r}, hb1, hb2) : {1'b0, sb_r};\n"
        "\n"
        "//  历史更新：第一个有效帧「装载」（中值=当帧值），丢失后清历史\n"
        "always @(posedge clk or negedge rst_n) begin\n"
        "    if(!rst_n) begin\n"
        "        hl1 <= {AW+1{1'b0}}; hl2 <= {AW+1{1'b0}};\n"
        "        hr1 <= {AW+1{1'b0}}; hr2 <= {AW+1{1'b0}};\n"
        "        ht1 <= {AW+1{1'b0}}; ht2 <= {AW+1{1'b0}};\n"
        "        hb1 <= {AW+1{1'b0}}; hb2 <= {AW+1{1'b0}};\n"
        "        have_hist <= 1'b0;\n"
        "    end\n"
        "    else if(vsync_fall) begin\n"
        "        if(!sany_r) have_hist <= 1'b0;\n"
        "        else if(!have_hist) begin\n"
        "            hl1 <= {1'b0, sl_r}; hl2 <= {1'b0, sl_r};\n"
        "            hr1 <= {1'b0, sr_r}; hr2 <= {1'b0, sr_r};\n"
        "            ht1 <= {1'b0, st_r}; ht2 <= {1'b0, st_r};\n"
        "            hb1 <= {1'b0, sb_r}; hb2 <= {1'b0, sb_r};\n"
        "            have_hist <= 1'b1;\n"
        "        end\n"
        "        else begin\n"
        "            hl2 <= hl1; hl1 <= {1'b0, sl_r};\n"
        "            hr2 <= hr1; hr1 <= {1'b0, sr_r};\n"
        "            ht2 <= ht1; ht1 <= {1'b0, st_r};\n"
        "            hb2 <= hb1; hb1 <= {1'b0, sb_r};\n"
        "        end\n"
        "    end\n"
        "end\n"
        "\n"
        "wire [AW:0]   cx_w = ({1'b0, sl_r} + {1'b0, sr_r}) >> 1;\n",
        'blob_track: 外框 3 帧中值')

# 1b) 用中值框导出的 cx/cy/bw/aim_y
old = ("wire [AW+8:0] cy_l = {9'd0, cy_w[AW-1:0]};\n"
       "wire [AW+8:0] ay_s = (cy_l >= up_t) ? (cy_l - up_t) : {(AW+9){1'b0}};\n")
new = ("wire [AW+8:0] cy_l = {9'd0, cy_w[AW-1:0]};\n"
       "wire [AW+8:0] ay_s = (cy_l >= up_t) ? (cy_l - up_t) : {(AW+9){1'b0}};\n"
       "\n"
       "//  同样的东西，但用「3 帧中值」后的外框（输出给下游用这个）\n"
       "wire [AW:0]     cx_f = (sl_f + sr_f) >> 1;\n"
       "wire [AW:0]     cy_f = (st_f + sb_f) >> 1;\n"
       "wire [AW:0]     bw_f = sr_f - sl_f + 1'b1;\n"
       "wire [2*AW+8:0] up_full_f = bw_f * aim_h_q8;\n"
       "wire [AW+8:0]   up_t_f    = up_full_f >> 8;\n"
       "wire [AW+8:0]   cy_l_f    = {9'd0, cy_f[AW-1:0]};\n"
       "wire [AW+8:0]   ay_f      = (cy_l_f >= up_t_f) ? (cy_l_f - up_t_f) : {(AW+9){1'b0}};\n")
t = sub(t, old, new, 'blob_track: 由中值框导出 cx/cy/bw/aim')

# 1c) 输出改用中值框（拆成两段：含中文注释的那行只换 ASCII 前缀，避免锚点对不上）
t = sub(t, "            bond_l    <= sl_r;\n"
           "            bond_r    <= sr_r;\n"
           "            bond_t    <= st_r;\n"
           "            bond_b    <= sb_r;\n"
           "            center_x  <= cx_w[AW-1:0];\n"
           "            center_y  <= cy_w[AW-1:0];\n"
           "            aim_x     <= cx_w[AW-1:0];\n",
        "            //  P14: 下游（矄准偏移 / 距离 / 下坠 / 圆环）统一用 3 帧中值后的框\n"
        "            bond_l    <= sl_f[AW-1:0];\n"
        "            bond_r    <= sr_f[AW-1:0];\n"
        "            bond_t    <= st_f[AW-1:0];\n"
        "            bond_b    <= sb_f[AW-1:0];\n"
        "            center_x  <= cx_f[AW-1:0];\n"
        "            center_y  <= cy_f[AW-1:0];\n"
        "            aim_x     <= cx_f[AW-1:0];\n",
        'blob_track: 输出改用中值框(上半)')
t = sub(t, "            aim_y     <= ay_s[AW-1:0];",
        "            aim_y     <= ay_f[AW-1:0];",
        'blob_track: aim_y 改用中值框')
t = t.replace("            bond_l    <= sl_f[AW-1:0];", "            bond_l    <= sl_f[AW-1:0];", 1)

# 1d) 极小团块免形状检查
t = sub(t, "        else if(r_used[mi] && (min_area_lo != 32'd0) &&\n"
           "                (r_area[mi] >= min_area_lo) && shp_ok_r[mi]) begin\n",
        "        //  P14：面积 <= 32 的极小团块免掉长宽比/填充率检查 —— 那个尺寸下量化误差主导，\n"
        "        //  检查只会把远处的绿灯误杀（症状：屏幕上有绿色高亮，但 bond_valid=0）。\n"
        "        else if(r_used[mi] && (min_area_lo != 32'd0) &&\n"
        "                (r_area[mi] >= min_area_lo) &&\n"
        "                (shp_ok_r[mi] || (r_area[mi] <= 32'd32))) begin\n",
        'blob_track: 小团块免形状检查')
save(rel, raw, t, crlf, enc)

# =====================================================================
# 2) aim_predict.v —— MOVE_Q4 16 -> 32
# =====================================================================
rel = 'rtl/aim_predict.v'
raw, t, crlf, enc = load(rel)
t = t.replace('\r\n', '\n')
t = sub(t, "    parameter [7:0] MOVE_Q4 = 8'd16     // |vx|+|vy| >= 它才算「在动」（16 = 1 px/帧）\n",
        "    //  P14：门限从 1px/帧 提到 2px/帧 —— 斜置屏幕下 cx/cy 有 ±1px 抖动，\n"
        "    //  1px 门限会被抖出「在动」，黄十字乱闪；2px 只承认真的在动。\n"
        "    parameter [7:0] MOVE_Q4 = 8'd32     // |vx|+|vy| >= 它才算「在动」（32 = 2 px/帧）\n",
        'aim_predict: MOVE_Q4 16 -> 32')
save(rel, raw, t, crlf, enc)

# =====================================================================
# 3) reg_file.v（UTF-8）—— 新增 0x12 flags2
# =====================================================================
rel = 'rtl/reg_file.v'
raw, t, crlf, enc = load(rel, 'utf-8')
t = t.replace('\r\n', '\n')
t = sub(t, "    output reg [7:0]   r_lead_auto,  // 0x11 P13 1 = 提前量由距离自动算\n",
        "    output reg [7:0]   r_lead_auto,  // 0x11 P13 1 = 提前量由距离自动算\n"
        "    output reg [7:0]   r_flags2   ,  // 0x12 P14 b0 = 强制打开 α-β 跟踪器\n",
        'reg_file: 加 r_flags2 端口')
t = sub(t, "        r_lead_auto<= 8'd1;       // 默认按距离自动算提前量\n",
        "        r_lead_auto<= 8'd1;       // 默认按距离自动算提前量\n"
        "        r_flags2   <= 8'd0;       // 默认不强制开跟踪器\n",
        'reg_file: r_flags2 复位')
t = sub(t, "                                8'h11: r_lead_auto<= data_t;\n",
        "                                8'h11: r_lead_auto<= data_t;\n"
        "                                8'h12: r_flags2   <= data_t;\n",
        'reg_file: 地址 0x12')
save(rel, raw, t, crlf, enc)

# =====================================================================
# 4) armor_vision.v —— 接线
# =====================================================================
rel = 'rtl/armor_vision.v'
raw, t, crlf, enc = load(rel)
t = t.replace('\r\n', '\n')
t = sub(t, "wire [7:0]    rf_syn_spd, rf_syn_r, rf_syn_en, rf_st_page, rf_lead_auto;\n",
        "wire [7:0]    rf_syn_spd, rf_syn_r, rf_syn_en, rf_st_page, rf_lead_auto, rf_flags2;\n"
        "wire          trk_on   ;   // TRK_EN | 0x12 bit0\n",
        'armor_vision: flags2/trk_on wire')
t = sub(t, "    .r_lead_auto(rf_lead_auto),\n",
        "    .r_lead_auto(rf_lead_auto),\n    .r_flags2   (rf_flags2   ),\n",
        'armor_vision: 接 r_flags2')
save(rel, raw, t, crlf, enc)
print('=== P14 稳定性/远灯修补完成 ===')
