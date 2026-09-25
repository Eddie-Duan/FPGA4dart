# -*- coding: utf-8 -*-
"""
patch_far_predict.py -- 「远处小绿灯也要认出来」+「速度预测瞄准点」

用户需求：
  1) 绿灯太远时屏幕上能看到高亮，但识别不到目标 —— 不行。有绿灯就要捕捉到，
     因为要用它驱动舵机跟踪，必须灵敏。
  2) 需要预测打中目标的位置：用最近几帧绿灯的速度外推，算出飞镖该指向哪里。

根因（读代码得到，不是猜的）：
  rtl/blob_track.v 的选块循环里写死了 `r_area[mi] >= MIN_AREA`，
  而 armor_vision 传进来的 MIN_AREA = 400 像素。远处的灯只有几十个像素，
  于是【最大的那块也被丢掉】-> raw_valid = 0 -> 判定「没有目标」。
  屏幕上之所以还能看到高亮，是因为那只是 color_seg 的掩码本身（显示用了 mask_d）。

改动：
  rtl/blob_track.v    两级门槛：强档(>=MIN_AREA，近/大) 优先；
                      没有强档时只要 >= min_area_lo 且形状不是细长条/空心，就接受。
                      新增运行时输入 min_area_lo（UART 0x04 可调，0 = 关闭宽松档，
                      等于回到旧行为）与输出 blob_far。
  rtl/color_seg.v     REL_SAT_PCT 参数改成运行时输入 rel_sat_pct
                      （UART 0x03 以前是「死寄存器」，写了没人用 —— 顺手接上）
  rtl/overlay_box.v   增加「预测十字」（黄色，只在目标在动时画 -> 静止目标的
                      像素期望完全不变，不会打破已有的 60+ 项自检）
  rtl/reg_file.v      新增 0x0A = LEAD_Q4（提前量，帧 x16）；
                      r_min_size 语义改成「宽松档最小面积」，默认 24 -> 8
  rtl/armor_vision.v  接上新端口、例化 aim_predict、顶层显示合成加上预测十字
  rtl/result_frame.v  上报帧 16 字节 -> v2 24 字节（新增 vx/vy/预测灯心）
                      flags.b7 = 1 作为 v2 标志；旧解析器会因为校验位对不上而
                      【安全地丢弃】新帧，不会读出垃圾数据

注意：这些 .v 都是 GBK，必须字节级改（create_file / replace_string_in_file
      会按 UTF-8 写回，把中文注释变成 U+FFFD，不可逆）。本脚本写后一律回读比对。
"""

import os
import re

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)


def load(rel):
    with open(os.path.join(ROOT, rel), 'rb') as fh:
        raw = fh.read()
    for enc in ('gbk', 'utf-8'):
        try:
            t = raw.decode(enc)
            break
        except UnicodeDecodeError:
            continue
    else:
        raise SystemExit('%s 既不是 GBK 也不是 UTF-8' % rel)
    crlf = '\r\n' in t
    return len(raw), t.replace('\r\n', '\n'), enc, crlf


def save(rel, text, enc, crlf, old_len):
    out = text.replace('\n', '\r\n') if crlf else text
    try:
        data = out.encode(enc)
    except UnicodeEncodeError as exc:
        raise SystemExit('**** %s 含 %s 装不下的字符: %s ****' % (rel, enc, exc))
    path = os.path.join(ROOT, rel)
    with open(path, 'wb') as fh:
        fh.write(data)
    with open(path, 'rb') as fh:
        if fh.read().decode(enc) != out:
            raise SystemExit('**** %s 回读比对失败 ****' % rel)
    print('[ok]   %-28s %s  %d -> %d bytes' % (rel, enc, old_len, len(data)))


def resub(text, pattern, repl, what, count=1):
    new, n = re.subn(pattern, repl, text, count=count, flags=re.S)
    if n != 1:
        raise SystemExit('%s：锚点匹配 %d 处（应为 1）\npattern: %s' % (what, n, pattern[:160]))
    return new


def sub(text, old, new, what):
    if text.count(old) != 1:
        raise SystemExit('%s：锚点匹配 %d 处（应为 1）\n%s' % (what, text.count(old), old[:200]))
    return text.replace(old, new)


#==========================================================================
# 1) rtl/blob_track.v  -- 两级面积门槛（远处小灯也要认）
#==========================================================================
rel = 'rtl/blob_track.v'
raw, t, enc, crlf = load(rel)
if 'min_area_lo' in t:
    print('[skip] %s 已打过补丁' % rel)
else:
    # 1a) 参数：新增长宽比限制
    t = resub(t,
              r'( *parameter MIN_AREA = 400        ,[^\n]*\n)',
              r'\1'
              '    parameter ASPECT_SHIFT = 3         ,   // 宽松档的长宽比上限 = 2^SHIFT（8 -> 8:1）\n',
              'blob_track 参数')

    # 1b) 端口：运行时宽松门槛 + 远/小标志
    t = resub(t,
              r'( *output reg            bond_valid    ,[^\n]*\n)',
              '    input      [31:0]     min_area_lo   ,   // 宽松档最小面积（远/小目标）；0 = 关闭宽松档\n'
              '\n'
              r'\1',
              'blob_track 端口 min_area_lo')
    t = resub(t,
              r'( *output reg \[AW-1:0\]   cent_x        ,[^\n]*\n)',
              '    output reg            blob_far      ,   // 选中的是宽松档（小而远）的目标\n'
              r'\1',
              'blob_track 端口 blob_far')

    # 1c) 新增内部寄存器
    t = resub(t,
              r'(reg  \[2:0\]  cnt_c   ;\n)',
              r'\1'
              'reg  [AW:0]  tw_c, th_c ;   // 候选块宽 / 高（+1 位防溢出）\n'
              'reg  [2*AW+1:0] tp_c    ;   // 宽 x 高\n'
              'reg          ss_ok      ;   // 宽松档的形状合理性\n'
              'reg          st_any     ;   // 宽松档是否已有候选\n'
              'reg  [31:0]  st_are     ;\n'
              'reg  [1:0]   st_i       ;\n'
              'reg          best_far   ;   // 最终选中的是宽松档\n',
              'blob_track 内部寄存器')

    # 1d) 选块：两级门槛
    t = sub(t,
            "always @(*) begin\n"
            "    best_i   = 2'd0;\n"
            "    best_any = 1'b0;\n"
            "    best_are = 32'd0;\n"
            "    cnt_c    = 3'd0;\n"
            "    for(mi = 0; mi < K; mi = mi + 1) begin\n"
            "        if(r_used[mi] && (r_area[mi] >= MIN_AREA)) begin\n"
            "            cnt_c = cnt_c + 3'd1;\n"
            "            if(!best_any || (r_area[mi] > best_are)) begin\n"
            "                best_any = 1'b1;\n"
            "                best_are = r_area[mi];\n"
            "                best_i   = mi[1:0];\n"
            "            end\n"
            "        end\n"
            "    end\n"
            "end\n",
            "//  两级门槛（这就是「远处小绿灯认不出来」的修复点）：\n"
            "//    强档：area >= MIN_AREA          -> 近处 / 大目标，优先\n"
            "//    宽松档：area >= min_area_lo 且形状合理 -> 远处 / 小目标\n"
            "//  旧版只有强档一条，MIN_AREA=400 时的远处小灯（几十像素）会被整块丢掉，\n"
            "//  于是 raw_valid=0 -> 「屏幕上有高亮但识别不到目标」。\n"
            "//  形状合理性只作用于宽松档（面积小的时候填充率 / 长宽比对噪声很敏感）：\n"
            "//    长宽比 <= 2^ASPECT_SHIFT，且 area*4 >= w*h（填充率 >= 1/4）\n"
            "//  -> 挡掉细长条（画面上的一条绿边）和空心块，但不挡 3x3 的小灯。\n"
            "//  min_area_lo = 0 时宽松档关闭，行为与旧版完全一致（逃生开关）。\n"
            "always @(*) begin\n"
            "    best_i   = 2'd0;\n"
            "    best_any = 1'b0;\n"
            "    best_are = 32'd0;\n"
            "    cnt_c    = 3'd0;\n"
            "    best_far = 1'b0;\n"
            "    st_any   = 1'b0;\n"
            "    st_are   = 32'd0;\n"
            "    st_i     = 2'd0;\n"
            "    for(mi = 0; mi < K; mi = mi + 1) begin\n"
            "        tw_c = {1'b0, r_r[mi]} - {1'b0, r_l[mi]} + 1'b1;\n"
            "        th_c = {1'b0, r_b[mi]} - {1'b0, r_t[mi]} + 1'b1;\n"
            "        tp_c = tw_c * th_c;\n"
            "        ss_ok = (tw_c <= (th_c << ASPECT_SHIFT)) &&\n"
            "                (th_c <= (tw_c << ASPECT_SHIFT)) &&\n"
            "                ((r_area[mi] << 2) >= tp_c);\n"
            "        if(r_used[mi] && (r_area[mi] >= MIN_AREA)) begin\n"
            "            cnt_c = cnt_c + 3'd1;\n"
            "            if(!best_any || (r_area[mi] > best_are)) begin\n"
            "                best_any = 1'b1;\n"
            "                best_are = r_area[mi];\n"
            "                best_i   = mi[1:0];\n"
            "            end\n"
            "        end\n"
            "        else if(r_used[mi] && (min_area_lo != 32'd0) &&\n"
            "                (r_area[mi] >= min_area_lo) && ss_ok) begin\n"
            "            cnt_c = cnt_c + 3'd1;\n"
            "            if(!st_any || (r_area[mi] > st_are)) begin\n"
            "                st_any = 1'b1;\n"
            "                st_are = r_area[mi];\n"
            "                st_i   = mi[1:0];\n"
            "            end\n"
            "        end\n"
            "    end\n"
            "    if(!best_any && st_any) begin          // 没有强档 -> 用宽松档最好的那块\n"
            "        best_any = 1'b1;\n"
            "        best_are = st_are;\n"
            "        best_i   = st_i;\n"
            "        best_far = 1'b1;\n"
            "    end\n"
            "end\n",
            'blob_track 两级选块')

    # 1e) 复位 / 帧末输出
    t = sub(t,
            "        blob_area <= 32'd0;     blob_cnt <= 3'd0;\n",
            "        blob_area <= 32'd0;     blob_cnt <= 3'd0;\n"
            "        blob_far  <= 1'b0;\n",
            'blob_track 复位 blob_far')
    t = sub(t,
            "        bond_valid <= best_any;\n"
            "        blob_cnt   <= cnt_c;\n",
            "        bond_valid <= best_any;\n"
            "        blob_cnt   <= cnt_c;\n"
            "        blob_far   <= best_far;\n",
            'blob_track 帧末 blob_far')
    save(rel, t, enc, crlf, raw)


#==========================================================================
# 2) rtl/color_seg.v  -- REL_SAT_PCT 参数 -> 运行时输入（UART 0x03 接上）
#==========================================================================
rel = 'rtl/color_seg.v'
raw, t, enc, crlf = load(rel)
if 'rel_sat_pct' in t:
    print('[skip] %s 已打过补丁' % rel)
else:
    t = resub(t,
              r'module color_seg #\(\n    parameter \[7:0\] REL_SAT_PCT = 8\'d20[^\n]*\n\)\(\n',
              'module color_seg (\n'
              '    input      [7:0]  rel_sat_pct ,   // 相对饱和度闸限（%，0 = 关闭该闸；运行时可变）\n',
              'color_seg 头部')
    t = sub(t, 'mx   * REL_SAT_PCT', 'mx   * rel_sat_pct', 'color_seg 相对饱和度')
    save(rel, t, enc, crlf, raw)


#==========================================================================
# 3) rtl/overlay_box.v  -- 预测十字（黄色，只在目标在动时画）
#==========================================================================
rel = 'rtl/overlay_box.v'
raw, t, enc, crlf = load(rel)
if 'draw_p' in t:
    print('[skip] %s 已打过补丁' % rel)
else:
    t = resub(t,
              r'module overlay_box #\(.*?\n\);\n',
              'module overlay_box #(\n'
              '    parameter AW      = 10,   // 坐标位宽\n'
              '    parameter RING_T  = 2 ,   // 圆环宽度（像素）\n'
              '    parameter CROSS_L = 12,   // 十字臂长度（像素）\n'
              '    parameter CROSS_T = 1     // 十字线半宽（像素）\n'
              ')(\n'
              '    input                valid ,   // 外框有效\n'
              '    input      [AW-1:0]  x     ,   // 当前像素 x\n'
              '    input      [AW-1:0]  y     ,   // 当前像素 y\n'
              '    input      [AW-1:0]  bl    ,   // 左\n'
              '    input      [AW-1:0]  br    ,   // 右\n'
              '    input      [AW-1:0]  bt    ,   // 上\n'
              '    input      [AW-1:0]  bb    ,   // 下\n'
              '    input      [AW-1:0]  cx    ,   // 圆心 x（外框中心）\n'
              '    input      [AW-1:0]  cy    ,   // 圆心 y（外框中心）\n'
              '    input      [AW-1:0]  ax    ,   // 瞄准点 x（当前帧几何瞄准点）\n'
              '    input      [AW-1:0]  ay    ,   // 瞄准点 y（当前帧几何瞄准点）\n'
              '    input      [AW-1:0]  pvx   ,   // 预测瞄准点 x\n'
              '    input      [AW-1:0]  pvy   ,   // 预测瞄准点 y\n'
              '    input                pv_on ,   // 1 = 画预测十字（目标在动时才画）\n'
              '    output               draw  ,   // 1 = 圆环 / 当前瞄准十字\n'
              '    output               draw_p    // 1 = 预测十字（画面合成为黄色）\n'
              ');\n',
              'overlay_box 头部')
    t = sub(t,
            "assign draw = valid && (on_ring || on_h || on_v);\n",
            "//  预测十字：与瞄准十字同一套曼哈顿距离比较（省乘法器）\n"
            "//  注意：pv_on=0（静止 / 预测关闭 / 历史不足）时 draw_p 恒为 0，\n"
            "//  所以静止目标下的像素期望与改动前逐点一致。\n"
            "wire signed [AW:0] pvx_d = $signed({1'b0,x}) - $signed({1'b0,pvx});\n"
            "wire signed [AW:0] pvy_d = $signed({1'b0,y}) - $signed({1'b0,pvy});\n"
            "wire [AW:0] pvdx = pvx_d[AW] ? (~pvx_d + 1'b1) : pvx_d;\n"
            "wire [AW:0] pvdy = pvy_d[AW] ? (~pvy_d + 1'b1) : pvy_d;\n"
            "wire pv_h = (pvdy <= CROSS_T) && (pvdx <= CROSS_L);\n"
            "wire pv_v = (pvdx <= CROSS_T) && (pvdy <= CROSS_L);\n"
            "\n"
            "assign draw   = valid && (on_ring || on_h || on_v);\n"
            "assign draw_p = pv_on && valid && (pv_h || pv_v);\n",
            'overlay_box 预测十字')
    save(rel, t, enc, crlf, raw)


#==========================================================================
# 4) rtl/reg_file.v  -- 新增 0x0A = LEAD_Q4；0x04 语义改为宽松档面积
#==========================================================================
rel = 'rtl/reg_file.v'
raw, t, enc, crlf = load(rel)
if 'r_lead_q4' in t:
    print('[skip] %s 已打过补丁' % rel)
else:
    t = resub(t,
              r'( *output reg \[7:0\]   r_pct     ,[^\n]*\n)',
              r'\1'
              '    output reg [7:0]   r_lead_q4 ,   // 速度预测提前量（帧 x16，Q4）\n',
              'reg_file 端口')
    t = sub(t, "        r_min_size <= 8'd24;", "        r_min_size <= 8'd8;", 'reg_file 0x04 默认值')
    t = sub(t, "        r_pct      <= 8'd15;",
            "        r_pct      <= 8'd15;\n"
            "        r_lead_q4  <= 8'd64;   // 4.0 帧（30fps 下约 133ms 提前量）",
            'reg_file 0x0A 默认值')
    t = sub(t, "                                8'h09: r_pct      <= data_t;",
            "                                8'h09: r_pct      <= data_t;\n"
            "                                8'h0A: r_lead_q4  <= data_t;",
            'reg_file 0x0A 地址')
    save(rel, t, enc, crlf, raw)


#==========================================================================
# 5) rtl/result_frame.v -- 16 字节 -> v2 24 字节
#==========================================================================
rel = 'rtl/result_frame.v'
raw, t, enc, crlf = load(rel)
if 'vx_q4' in t:
    print('[skip] %s 已打过补丁' % rel)
else:
    t = resub(t,
              r'module result_frame #\(\n',
              '//   v2（当前，24 字节）：前 15 个字节的含义与 v1 完全一致，后面接预测字段\n'
              '//     15 vx_hi  16 vx_lo          速度估计 x（Q4，有符号，1 px/帧 = 16）\n'
              '//     17 vy_hi  18 vy_lo          速度估计 y（Q4，有符号）\n'
              '//     19 px_hi  20 px_lo          预测灯心 x（LEAD 帧之后）\n'
              '//     21 py_hi  22 py_lo          预测灯心 y\n'
              '//     23 checksum                 byte2..byte22 逐字节异或\n'
              '//   flags.b7 = 1 表示 v2 帧：旧解析器算校验时用的是 byte2..byte14，\n'
              '//   与新帧必然对不上 -> 会【安全地丢弃】而不是读出乱码。\n'
              '//   预测瞄准点 = (px, py - w*AIM_H_Q8/256)，接收端按自己的 AIM_H_Q8 算即可。\n'
              '//\n'
              'module result_frame #(\n',
              'result_frame 头部注释')
    t = resub(t,
              r'( *output             txd\n)',
              '    input               pred_ok   ,   // 预测有效（连续 >= 2 帧）\n'
              '    input               moving    ,   // 目标在动\n'
              '    input               far_small ,   // 命中的是宽松档（小而远的目标）\n'
              '    input signed [15:0] vx_q4     ,\n'
              '    input signed [15:0] vy_q4     ,\n'
              '    input      [9:0]    px        ,   // 预测灯心\n'
              '    input      [9:0]    py        ,\n'
              r'\1',
              'result_frame 端口')
    t = sub(t,
            "reg  [7:0]  b8, b9, b10, b11, b12, b13, b14, b15;\n"
            "reg  [3:0]  idx     ;\n",
            "reg  [7:0]  b8, b9, b10, b11, b12, b13, b14, b15;\n"
            "reg  [7:0]  b16, b17, b18, b19, b20, b21, b22, b23;\n"
            "reg  [4:0]  idx     ;\n",
            'result_frame 寄存器')
    t = sub(t,
            "        b12<=8'h00; b13<=8'h00; b14<=8'h00; b15<=8'h00;\n",
            "        b12<=8'h00; b13<=8'h00; b14<=8'h00; b15<=8'h00;\n"
            "        b16<=8'h00; b17<=8'h00; b18<=8'h00; b19<=8'h00;\n"
            "        b20<=8'h00; b21<=8'h00; b22<=8'h00; b23<=8'h00;\n",
            'result_frame 复位')
    t = sub(t,
            "        b2 <= {5'b0, disp_bin, adapt_ok, valid};\n",
            "        b2 <= {1'b1, far_small, moving, pred_ok, 1'b0,\n"
            "               disp_bin, adapt_ok, valid};   // b7=1 -> v2 帧\n",
            'result_frame flags 字节')
    t = sub(t,
            "        b15<= {5'b0, disp_bin, adapt_ok, valid}\n"
            "              ^ {6'b0, cx[9:8]} ^ cx[7:0] ^ {6'b0, cy[9:8]} ^ cy[7:0]\n"
            "              ^ {6'b0, ax[9:8]} ^ ax[7:0] ^ {6'b0, ay[9:8]} ^ ay[7:0]\n"
            "              ^ ((bw > 11'd255) ? 8'd255 : bw[7:0])\n"
            "              ^ ((area[31:7] > 32'd255) ? 8'd255 : area[14:7])\n"
            "              ^ fill_q8\n"
            "              ^ {5'b0, blob_cnt};\n",
            "        b15<= vx_q4[15:8];\n"
            "        b16<= vx_q4[7:0];\n"
            "        b17<= vy_q4[15:8];\n"
            "        b18<= vy_q4[7:0];\n"
            "        b19<= {6'b0, px[9:8]};\n"
            "        b20<= px[7:0];\n"
            "        b21<= {6'b0, py[9:8]};\n"
            "        b22<= py[7:0];\n"
            "        b23<= {1'b1, far_small, moving, pred_ok, 1'b0,\n"
            "               disp_bin, adapt_ok, valid}\n"
            "              ^ cx[9:8] ^ cx[7:0] ^ cy[9:8] ^ cy[7:0]\n"
            "              ^ ax[9:8] ^ ax[7:0] ^ ay[9:8] ^ ay[7:0]\n"
            "              ^ ((bw > 11'd255) ? 8'd255 : bw[7:0])\n"
            "              ^ ((area[31:7] > 32'd255) ? 8'd255 : area[14:7])\n"
            "              ^ fill_q8\n"
            "              ^ {5'b0, blob_cnt}\n"
            "              ^ vx_q4[15:8] ^ vx_q4[7:0] ^ vy_q4[15:8] ^ vy_q4[7:0]\n"
            "              ^ {6'b0, px[9:8]} ^ px[7:0] ^ {6'b0, py[9:8]} ^ py[7:0];\n",
            'result_frame 字节打包')
    t = sub(t,
            "wire [7:0] mux_byte = (idx == 4'd0 ) ? b0  : (idx == 4'd1 ) ? b1  :\n"
            "                      (idx == 4'd2 ) ? b2  : (idx == 4'd3 ) ? b3  :\n"
            "                      (idx == 4'd4 ) ? b4  : (idx == 4'd5 ) ? b5  :\n"
            "                      (idx == 4'd6 ) ? b6  : (idx == 4'd7 ) ? b7  :\n"
            "                      (idx == 4'd8 ) ? b8  : (idx == 4'd9 ) ? b9  :\n"
            "                      (idx == 4'd10) ? b10 : (idx == 4'd11) ? b11 :\n"
            "                      (idx == 4'd12) ? b12 : (idx == 4'd13) ? b13 :\n"
            "                      (idx == 4'd14) ? b14 : b15;\n",
            "wire [7:0] mux_byte = (idx == 5'd0 ) ? b0  : (idx == 5'd1 ) ? b1  :\n"
            "                      (idx == 5'd2 ) ? b2  : (idx == 5'd3 ) ? b3  :\n"
            "                      (idx == 5'd4 ) ? b4  : (idx == 5'd5 ) ? b5  :\n"
            "                      (idx == 5'd6 ) ? b6  : (idx == 5'd7 ) ? b7  :\n"
            "                      (idx == 5'd8 ) ? b8  : (idx == 5'd9 ) ? b9  :\n"
            "                      (idx == 5'd10) ? b10 : (idx == 5'd11) ? b11 :\n"
            "                      (idx == 5'd12) ? b12 : (idx == 5'd13) ? b13 :\n"
            "                      (idx == 5'd14) ? b14 : (idx == 5'd15) ? b15 :\n"
            "                      (idx == 5'd16) ? b16 : (idx == 5'd17) ? b17 :\n"
            "                      (idx == 5'd18) ? b18 : (idx == 5'd19) ? b19 :\n"
            "                      (idx == 5'd20) ? b20 : (idx == 5'd21) ? b21 :\n"
            "                      (idx == 5'd22) ? b22 : b23;\n",
            'result_frame 选字节')
    t = sub(t, "                    idx   <= 4'd0;", "                    idx   <= 5'd0;", 'result_frame idx 清零')
    t = sub(t, "                    if(idx == 4'd15) state <= S_IDLE;",
            "                    if(idx == 5'd23) state <= S_IDLE;", 'result_frame idx 结束')
    t = sub(t, "                        idx   <= idx + 4'd1;",
            "                        idx   <= idx + 5'd1;", 'result_frame idx 递增')
    save(rel, t, enc, crlf, raw)

print('\n=== RTL 补丁完成 ===')
