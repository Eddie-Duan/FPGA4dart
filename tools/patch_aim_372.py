# -*- coding: utf-8 -*-
"""
patch_aim_372.py -- 把瞄准点参数改成真实靶标的几何（AIM_H_Q8 = 372）

背景（用户给的靶标规格）：
    灯直径 Dt = 55mm，打击点在灯心上方 dh = 80mm
    -> AIM_H_Q8 = 256 * 80/55 = 372  (= 1.449 倍灯直径)

为什么必须改：
  1) 现在是 parameter [7:0] AIM_H_Q8 = 8'd64，8 bit 最大 255 -> 装不下 372，
     而 blob_track 那边没写位宽，会被【静默截断】成 372-256 = 116（= 0.45 倍）。
  2) 偏移 = 1.449 x 灯宽。仿真里灯宽 201px -> 292px，比灯心 y(248) 还大
     -> aim_y = cy - up 是无符号减法，会【下溢回绕】到 1023 附近，十字跳到画面底部。
     所以必须补饱和减法。

改动清单：
  rtl/blob_track.v   参数显式 16bit + aim_y 改饱和减法
  rtl/armor_vision.v 参数 16bit、默认 16'd372；UART 寄存器 0x05 接上（低位小数）
  rtl/reg_file.v     r_aim_h 复位值 64 -> 116（= 372 & 0xFF，保证默认一致）
  sim/tb_armor_vision.v  主实例钉 16'd64 保持原有几何期望不变；
                         另加一个 AIM_H_Q8=372 的实例专门验证饱和

注意：这些文件是 GBK，必须字节级改（不能 create_file / replace_string_in_file）。
"""

import os
import re

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
SKIP_TOKEN = 'aim_h_eff'          # 出现即认为已打过补丁


def load(rel):
    """返回 (原始长度, 归一化成 \\n 的文本, 编码, 原本是不是 CRLF)"""
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
    path = os.path.join(ROOT, rel)
    out = text.replace('\n', '\r\n') if crlf else text
    data = out.encode(enc)
    with open(path, 'wb') as fh:
        fh.write(data)
    with open(path, 'rb') as fh:
        if fh.read().decode(enc) != out:
            raise SystemExit('**** %s 回读比对失败 ****' % rel)
    print('[ok]   %-28s %s  %d -> %d bytes' % (rel, enc, old_len, len(data)))


def sub1(text, old, new, what):
    n = text.count(old)
    if n != 1:
        raise SystemExit('%s：锚点匹配 %d 处（应为 1）\n%s' % (what, n, old[:200]))
    return text.replace(old, new)


#==========================================================================
# 1) rtl/blob_track.v
#==========================================================================
rel = 'rtl/blob_track.v'
raw, t, enc, crlf = load(rel)
if '[15:0] AIM_H_Q8' in t:
    print('[skip] %s 已打过补丁' % rel)
else:
    # 1a) 参数显式 16bit（原来没写位宽，高位会被静默截断）
    t = sub1(t,
             "    parameter AIM_H_Q8 = 8'd64",
             "    parameter [15:0] AIM_H_Q8 = 16'd64",
             'blob_track 参数')

    # 1b) 饱和减法：先把两个量补到 19bit 再比，避免 cy < up 时回绕
    t = sub1(t,
             "wire [2*AW+8:0] up_full = bw_w * AIM_H_Q8;\n"
             "wire [AW+8:0]   up_t    = up_full >> 8;",
             "wire [2*AW+8:0] up_full = bw_w * AIM_H_Q8;\n"
             "wire [AW+8:0]   up_t    = up_full >> 8;\n"
             "\n"
             "//  饱和减法 aim_y = cy - up\n"
             "//  直接写 aim_y <= cy - up 时，两边按 10bit 运算，cy < up 就下溢回绕\n"
             "//  (绕到 1024 附近，十字跳到画面底部)。\n"
             "//  AIM_H_Q8 = 372 时偏移 = 1.449 x 灯宽，必然超过灯心 y，所以必须先补这里。\n"
             "wire [AW+8:0] cy_l = {9'd0, cy_w[AW-1:0]};\n"
             "wire [AW+8:0] ay_s = (cy_l >= up_t) ? (cy_l - up_t) : {(AW+9){1'b0}};",
             'blob_track 饱和减法声明')

    t = sub1(t,
             "            aim_y     <= cy_w[AW-1:0] - up_t[AW-1:0];",
             "            aim_y     <= ay_s[AW-1:0];       // 饱和，不回绕",
             'blob_track aim_y 赋值')
    save(rel, t, enc, crlf, raw)


#==========================================================================
# 2) rtl/armor_vision.v
#==========================================================================
rel = 'rtl/armor_vision.v'
raw, t, enc, crlf = load(rel)
if SKIP_TOKEN in t:
    print('[skip] %s 已打过补丁' % rel)
else:
    # 2a) 参数 16bit、默认 372。整行替换（原注释「默认 1/4」已过期，一并去掉）
    pat = re.compile(r"^[ \t]*parameter \[7:0\] AIM_H_Q8 = 8'd64[^\r\n]*$", re.M)
    hit = pat.findall(t)
    if len(hit) != 1:
        raise SystemExit('armor_vision 参数行匹配 %d 处（应为 1）' % len(hit))
    t = pat.sub(
        "    //  瞄准点偏移 = 宽度 x AIM_H_Q8/256，Q0.8 定点。\n"
        "    //  真实靶标：打击点在灯心上方 80mm、灯直径 55mm\n"
        "    //  -> 256*80/55 = 372（= 1.449 倍灯直径，不是 1/4）。\n"
        "    //  注意：必须 >= 9bit。写成 8bit 装不下 372，会被静默截断成 116（= 0.45 倍）。\n"
        "    parameter [15:0] AIM_H_Q8 = 16'd372 ,",
        t, count=1)

    # 2b) 把 UART 寄存器 0x05 接上：只覆盖低 8 位（小数部分），整数部分由参数给。
    #     这样 372 在「写过寄存器」之后依然成立，而且 0x05 从「文档里有、代码里没接」
    #     变成真的能用（微调用，步长 1/256 = 0.0039 倍灯直径）。
    t = sub1(t,
             "blob_track #(",
             "//  UART 写 0x05 后，偏移取 {参数高 8 位, 寄存器低 8 位}。\n"
             "//  372 = 16'h0174 -> 高 8 位 1、低 8 位 0x74(116)，reg_file 的复位值也是 116，\n"
             "//  所以只写别的阈值寄存器不会把瞄准高度改掉。\n"
             "wire [15:0] aim_h_eff = reg_written ? {AIM_H_Q8[15:8], rf_aim_h} : AIM_H_Q8;\n"
             "\n"
             "blob_track #(",
             'armor_vision aim_h_eff 接线')

    t = sub1(t, ".AIM_H_Q8 (AIM_H_Q8 )", ".AIM_H_Q8 (aim_h_eff )", 'armor_vision 实例参数')
    save(rel, t, enc, crlf, raw)


#==========================================================================
# 3) rtl/reg_file.v -- 复位值改成 372 的低 8 位，保证默认与参数一致
#==========================================================================
rel = 'rtl/reg_file.v'
raw, t, enc, crlf = load(rel)
if "8'd116" in t:
    print('[skip] %s 已打过补丁' % rel)
else:
    t = sub1(t, "r_aim_h    <= 8'd64;",
             "r_aim_h    <= 8'd116;   // = 372 & 0xFF，与 armor_vision 的 AIM_H_Q8 默认一致",
             'reg_file r_aim_h 复位值')
    save(rel, t, enc, crlf, raw)


#==========================================================================
# 4) sim/tb_armor_vision.v
#==========================================================================
rel = 'sim/tb_armor_vision.v'
raw, t, enc, crlf = load(rel)
if 'u_blob_real' in t:
    print('[skip] %s 已打过补丁' % rel)
else:
    # 4a) 主实例钉死 64，保持原有几何期望值不变（瞄准点在画面内才好比大小）
    t = sub1(t, ".AIM_H_Q8    (8'd64      ),", ".AIM_H_Q8    (16'd64      ),", 'tb 主实例参数')

    # 4b) 另加一个 372 的实例，专门验证「偏移超出画面时必须饱和」
    #     锚点用「u_vision_stat_test 之后的第一个 \n);」（= 该实例的结束），
    #     比逐字匹配端口对齐空格稳。
    REAL_BLOCK = """
//-------------------------------------------------------
// 真实靶标参数（AIM_H_Q8 = 372）的验证实例
//   本靶标：打击点在灯心上方 80mm、灯直径 55mm -> 1.449 倍灯直径
//   仿真图：灯心 y=248、灯宽约 201px -> 偏移 = 201*372/256 = 292px
//   292 > 248，瞄准点必然跑到画面上方之外 -> 必须【饱和到 0】。
//   如果这里读到 1023 附近，就是无符号下溢回绕（十字会跳到画面底部）。
//-------------------------------------------------------
wire        real_valid;
wire [9:0]  real_cx, real_cy, real_ax, real_ay;

blob_track #(
    .WIDTH    (800     ),
    .HEIGHT   (480     ),
    .AW       (10      ),
    .MIN_AREA (400     ),
    .AIM_H_Q8 (16'd372 )
) u_blob_real (
    .clk        (clk                    ),
    .rst_n      (rst_n                  ),
    .vsync      (vsync                  ),
    .de         (u_armor_vision.de_v    ),
    .x          (u_armor_vision.x_v     ),
    .y          (u_armor_vision.y_cnt   ),
    .mask       (u_armor_vision.mask_d  ),
    .bond_valid (real_valid             ),
    .bond_l     (                       ),
    .bond_r     (                       ),
    .bond_t     (                       ),
    .bond_b     (                       ),
    .center_x   (real_cx                ),
    .center_y   (real_cy                ),
    .aim_x      (real_ax                ),
    .aim_y      (real_ay                ),
    .blob_area  (                       ),
    .blob_cnt   (                       ),
    .cent_x     (                       ),
    .cent_y     (                       ),
    .fill_q8    (                       )
);
"""
    i = t.index('u_vision_stat_test (')
    j = t.index('\n);', i) + 3
    t = t[:j] + REAL_BLOCK + t[j:]

    # 4c) 检查项，插在相位 1 的 aim_y 之后
    t = sub1(t,
             '    chk_near("aim_y",   aim_y              , EXP_AY  , 32\'d2);',
             '    chk_near("aim_y",   aim_y              , EXP_AY  , 32\'d2);\n'
             '    //  真实靶标参数 372：圆心不变，但偏移 292px > 灯心 y -> 必须饱和到 0\n'
             '    chk("real_bond_v",  real_valid         , 32\'d1   );\n'
             '    chk("real_center_y", real_cy           , EXP_CY  );\n'
             '    chk("real_aim_x",    real_ax           , EXP_CX  );\n'
             '    chk("real_aim_y_sat", real_ay          , 32\'d0   );',
             'tb 372 检查项')
    save(rel, t, enc, crlf, raw)

print('\n全部完成。下一步：xvlog 语法检查 -> 重跑仿真 -> OOC 综合。')
