# -*- coding: utf-8 -*-
"""
patch_blob_timing.py -- 修 blob_track 在 50MHz 下的 setup 违例（WNS -5.242ns）

实测（impl_1/timing_summary_routed.rpt，2026-09）：
    clk_out2_clk_wiz_0（50MHz，20ns 要求）
    u_armor_vision/u_blob_track/r_l_reg[0][6]/C
      -> u_armor_vision/u_blob_track/aim_y_reg[9]/D
    25.160ns（logic 14.313 + route 10.847）-> WNS -5.242ns
    失败的 10 个端点 = aim_y_reg[9:0]，就是这一条路径的 10 位。
    除此之外全设计最好的一条也有 +0.98ns（MIG 内部），也就是「只有这一条要修」。

根因：一行组合逻辑里塞了两件事
    (1) 选块：4 个候选各一个 `w*h` 乘法 + 长宽比/填充率比较 + 两级优先树
    (2) 几何换算：bw * aim_h_q8 -> >>8 -> 饱和减法 -> aim_y
数据在一帧内是「准静态」的（只有 emit 才改记录、只有 vsync 下降沿才取用），
所以拆成流水线对功能零影响。本脚本把它拆成三级：

    级 0（组合）  形状合理性：4 个候选并行算 w*h + 比较 -> shp_now
    级 1（寄存器）shp_ok_r        <- shp_now        （乘法移出选块路径）
    级 2（寄存器）best_i_r / best_any_r / best_far_r / cnt_r <- 选块结果
    级 3（寄存器）sl_r/sr_r/st_r/sb_r/sa_r/sx_r/sy_r + sany_r/sfar_r/scnt_r
    级 3 之后（组合）cx_w / cy_w / bw_w / up_t / ay_s -> 在 vsync_fall 采样

    关键：记录在 vsync_fall 那一拍才清零，而输出端用的是【清零之前】就已经
    打进去的值，所以多几拍不会改变任何结果（延迟远小于一帧 22ms）。

文件是 GBK，字节级改 + 回读比对。
"""

import os

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
REL = 'rtl/blob_track.v'


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
        raise SystemExit('%s 编码未知' % rel)
    crlf = '\r\n' in t
    return len(raw), t.replace('\r\n', '\n'), enc, crlf


def save(rel, text, enc, crlf, old_len):
    out = text.replace('\n', '\r\n') if crlf else text
    data = out.encode(enc)
    with open(os.path.join(ROOT, rel), 'wb') as fh:
        fh.write(data)
    with open(os.path.join(ROOT, rel), 'rb') as fh:
        if fh.read().decode(enc) != out:
            raise SystemExit('**** 回读比对失败 ****')
    print('[ok]   %-24s %s  %d -> %d bytes' % (rel, enc, old_len, len(data)))


def sub(t, old, new, what):
    if t.count(old) != 1:
        raise SystemExit('%s：锚点匹配 %d 处（应为 1）' % (what, t.count(old)))
    return t.replace(old, new)


def repl_lines(t, first_ascii, n_lines, new_text, what):
    """把「以 first_ascii 开头的那一行」开始共 n_lines 行整体替换掉
    （用行首 ASCII 做锚点，避免依赖 GBK 的中文注释）"""
    i = t.find(first_ascii)
    if i < 0:
        raise SystemExit('%s：找不到锚点 %r' % (what, first_ascii))
    if t.count(first_ascii) != 1:
        raise SystemExit('%s：锚点 %r 匹配 %d 处' % (what, first_ascii, t.count(first_ascii)))
    j = t.find('\n', i)
    for _ in range(n_lines - 1):
        j = t.find('\n', j + 1)
        if j < 0:
            raise SystemExit('%s：行数不够' % what)
    return t[:i] + new_text + t[j + 1:]


raw, t, enc, crlf = load(REL)

if 'shp_ok_r' in t:
    print('[skip] %s 已打过补丁' % REL)
    raise SystemExit(0)

#--------------------------------------------------------------------------
# 1) 声明：tw_c/th_c/tp_c/ss_ok 换成「形状 flag 寄存器 + 三级流水寄存器」
#--------------------------------------------------------------------------
t = repl_lines(
    t,
    "reg  [AW:0]  tw_c, th_c ;",
    7,
    "//  ---- 形状合理性（打一拍，把 w*h 乘法移出选块路径）----\n"
    "reg  [AW:0]  tw_f, th_f ;   // 候选项宽 / 高（组合过桥）\n"
    "reg  [K-1:0] shp_now    ;   // 组合：4 个候选的形状结论\n"
    "reg  [K-1:0] shp_ok_r   ;   // 打一拍后的形状结论\n"
    "reg          st_any     ;   // 宽松档是否已有候选\n"
    "reg  [31:0]  st_are     ;\n"
    "reg  [1:0]   st_i       ;\n"
    "reg          best_far   ;   // 最终选中的是宽松档\n"
    "integer      si         ;\n"
    "\n"
    "//  ---- 三级流水（数据在帧内准静态，拆开对功能零影响）----\n"
    "reg  [1:0]   best_i_r   ;   // 级1：选块结果\n"
    "reg          best_any_r ;\n"
    "reg          best_far_r ;\n"
    "reg  [2:0]   cnt_r      ;\n"
    "reg  [AW-1:0] sl_r, sr_r, st_r, sb_r;   // 级2：选中记录的外框\n"
    "reg  [31:0]  sa_r, sx_r, sy_r;          // 级2：面积 / 矩\n"
    "reg          sany_r, sfar_r;\n"
    "reg  [2:0]   scnt_r     ;\n",
    '声明块')

#--------------------------------------------------------------------------
# 2) 组合：4 个候选的形状合理性（并行，不参与选块的优先树）
#--------------------------------------------------------------------------
t = sub(t,
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
        "        if(r_used[mi] && (r_area[mi] >= MIN_AREA)) begin\n",
        "//  形状合理性：4 个候选并行算（只有乘法 + 比较，没有优先树）\n"
        "//  时序上单独一拍算完 -> 选块那边直接用 shp_ok_r[mi]\n"
        "always @(*) begin\n"
        "    for(si = 0; si < K; si = si + 1) begin\n"
        "        tw_f = {1'b0, r_r[si]} - {1'b0, r_l[si]} + 1'b1;\n"
        "        th_f = {1'b0, r_b[si]} - {1'b0, r_t[si]} + 1'b1;\n"
        "        shp_now[si] = (tw_f <= (th_f << ASPECT_SHIFT)) &&\n"
        "                      (th_f <= (tw_f << ASPECT_SHIFT)) &&\n"
        "                      ((r_area[si] << 2) >= (tw_f * th_f));\n"
        "    end\n"
        "end\n"
        "\n"
        "//  级1：形状结论打一拍\n"
        "always @(posedge clk or negedge rst_n) begin\n"
        "    if(!rst_n) shp_ok_r <= {K{1'b0}};\n"
        "    else       shp_ok_r <= shp_now;\n"
        "end\n"
        "\n"
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
        "        if(r_used[mi] && (r_area[mi] >= MIN_AREA)) begin\n",
        '形状合理性独立成块')

t = sub(t,
        "        else if(r_used[mi] && (min_area_lo != 32'd0) &&\n"
        "                (r_area[mi] >= min_area_lo) && ss_ok) begin\n",
        "        else if(r_used[mi] && (min_area_lo != 32'd0) &&\n"
        "                (r_area[mi] >= min_area_lo) && shp_ok_r[mi]) begin\n",
        '选块用打拍后的形状结论')

#--------------------------------------------------------------------------
# 3) 级2：选块结果打一拍；级3：选中记录打一拍；之后才做几何换算
#    （注意：bsel_* 那 7 行和下面的 cx_w/cy_w/bw_w 之间夹着一行中文注释，
#      不能用一整块锚点 —— 分两次改）
#--------------------------------------------------------------------------
t = repl_lines(
    t,
    "wire [AW-1:0] bsel_l = r_l[best_i];",
    7,
    "//  级2：选块结果打一拍\n"
    "always @(posedge clk or negedge rst_n) begin\n"
    "    if(!rst_n) begin\n"
    "        best_i_r   <= 2'd0;\n"
    "        best_any_r <= 1'b0;\n"
    "        best_far_r <= 1'b0;\n"
    "        cnt_r      <= 3'd0;\n"
    "    end\n"
    "    else begin\n"
    "        best_i_r   <= best_i;\n"
    "        best_any_r <= best_any;\n"
    "        best_far_r <= best_far;\n"
    "        cnt_r      <= cnt_c;\n"
    "    end\n"
    "end\n"
    "\n"
    "//  级3：选中记录的外框 / 面积 / 矩打一拍\n"
    "//  -> 后面的 bw * aim_h_q8 只从本地寄存器出发，布线短、级数少\n"
    "always @(posedge clk or negedge rst_n) begin\n"
    "    if(!rst_n) begin\n"
    "        sl_r <= {AW{1'b0}}; sr_r <= {AW{1'b0}};\n"
    "        st_r <= {AW{1'b0}}; sb_r <= {AW{1'b0}};\n"
    "        sa_r <= 32'd0; sx_r <= 32'd0; sy_r <= 32'd0;\n"
    "        sany_r <= 1'b0; sfar_r <= 1'b0; scnt_r <= 3'd0;\n"
    "    end\n"
    "    else begin\n"
    "        sl_r <= r_l[best_i_r];  sr_r <= r_r[best_i_r];\n"
    "        st_r <= r_t[best_i_r];  sb_r <= r_b[best_i_r];\n"
    "        sa_r <= r_area[best_i_r];\n"
    "        sx_r <= r_s2x[best_i_r];\n"
    "        sy_r <= r_s2y[best_i_r];\n"
    "        sany_r <= best_any_r;\n"
    "        sfar_r <= best_far_r;\n"
    "        scnt_r <= cnt_r;\n"
    "    end\n"
    "end\n",
    '级2/级3 流水')

t = sub(t,
        "wire [AW:0]   cx_w = ({1'b0, bsel_l} + {1'b0, bsel_r}) >> 1;\n"
        "wire [AW:0]   cy_w = ({1'b0, bsel_t} + {1'b0, bsel_b}) >> 1;\n"
        "wire [AW:0]   bw_w = {1'b0, bsel_r} - {1'b0, bsel_l} + 1'b1;\n",
        "wire [AW:0]   cx_w = ({1'b0, sl_r} + {1'b0, sr_r}) >> 1;\n"
        "wire [AW:0]   cy_w = ({1'b0, st_r} + {1'b0, sb_r}) >> 1;\n"
        "wire [AW:0]   bw_w = {1'b0, sr_r} - {1'b0, sl_r} + 1'b1;\n",
        '几何换算改用打拍后的值')

#--------------------------------------------------------------------------
# 4) 帧末采样：改用打拍后的值
#--------------------------------------------------------------------------
t = sub(t,
        "        bond_valid <= best_any;\n"
        "        blob_cnt   <= cnt_c;\n"
        "        blob_far   <= best_far;\n"
        "        if(best_any) begin\n"
        "            bond_l    <= bsel_l;\n"
        "            bond_r    <= bsel_r;\n"
        "            bond_t    <= bsel_t;\n"
        "            bond_b    <= bsel_b;\n",
        "        bond_valid <= sany_r;\n"
        "        blob_cnt   <= scnt_r;\n"
        "        blob_far   <= sfar_r;\n"
        "        if(sany_r) begin\n"
        "            bond_l    <= sl_r;\n"
        "            bond_r    <= sr_r;\n"
        "            bond_t    <= st_r;\n"
        "            bond_b    <= sb_r;\n",
        '帧末采样（外框）')

t = sub(t,
        "            blob_area <= bsel_a;\n"
        "            lat_x <= bsel_x;\n"
        "            lat_y <= bsel_y;\n"
        "            lat_a <= bsel_a;\n"
        "            lat_l <= bsel_l; lat_r <= bsel_r;\n"
        "            lat_t <= bsel_t; lat_b <= bsel_b;\n",
        "            blob_area <= sa_r;\n"
        "            lat_x <= sx_r;\n"
        "            lat_y <= sy_r;\n"
        "            lat_a <= sa_r;\n"
        "            lat_l <= sl_r; lat_r <= sr_r;\n"
        "            lat_t <= st_r; lat_b <= sb_r;\n",
        '帧末采样（面积/矩）')

t = sub(t,
        "            dv_dend  <= bsel_x;\n"
        "            dv_dsor  <= bsel_a << 1;",
        "            dv_dend  <= sx_r;\n"
        "            dv_dsor  <= sa_r << 1;",
        '帧末采样（除法器）')

save(REL, t, enc, crlf, raw)
print('=== 完成：剩下要做的就是把 GBK 转好的文件重新跑仿真 + 实现 ===')
