# -*- coding: utf-8 -*-
"""
patch_far_predict_fix.py -- 修两处 xvlog 报错（armor_vision.v）

1) min_area_lo_eff / rel_sat_eff / lead_q4_eff 被声明了两次
   （6b 里声明了 wire，6e 里又带初值声明了一次） -> 第二次改成 assign
2) 'bond_w' is already implicitly declared
   -> aim_predict 的例化被插在 bond_w 的 reg 声明【之前】，xvlog 不允许
      「先用后声明」。把整段例化搬到 (9c) 那段 assign 之后（那里 bond_w 已经声明好）。
"""

import os

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
REL = 'rtl/armor_vision.v'


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
    data = out.encode(enc)
    with open(os.path.join(ROOT, rel), 'wb') as fh:
        fh.write(data)
    with open(os.path.join(ROOT, rel), 'rb') as fh:
        if fh.read().decode(enc) != out:
            raise SystemExit('**** %s 回读比对失败 ****' % rel)
    print('[ok]   %-28s %s  %d -> %d bytes' % (rel, enc, old_len, len(data)))


def sub(text, old, new, what):
    if text.count(old) != 1:
        raise SystemExit('%s：锚点匹配 %d 处（应为 1）' % (what, text.count(old)))
    return text.replace(old, new)


raw, t, enc, crlf = load(REL)

#--------------------------------------------------------------------------
# 1) 重复声明 -> assign
#--------------------------------------------------------------------------
t = sub(t,
        "wire [31:0] min_area_lo_eff = reg_written ? {24'd0, rf_min_size} : MIN_AREA_LO_DEF;\n"
        "//  相对饱和度闸限（UART 0x03）：以前是死寄存器，现在真的接上了\n"
        "wire [7:0]  rel_sat_eff     = reg_written ? rf_rel_sat : REL_SAT_PCT;\n"
        "//  预测提前量（UART 0x0A）\n"
        "wire [7:0]  lead_q4_eff     = reg_written ? rf_lead_q4 : LEAD_Q4_DEF;\n",
        "assign min_area_lo_eff = reg_written ? {24'd0, rf_min_size} : MIN_AREA_LO_DEF;\n"
        "//  相对饱和度闸限（UART 0x03）：以前是死寄存器，现在真的接上了\n"
        "assign rel_sat_eff     = reg_written ? rf_rel_sat : REL_SAT_PCT;\n"
        "//  预测提前量（UART 0x0A）\n"
        "assign lead_q4_eff     = reg_written ? rf_lead_q4 : LEAD_Q4_DEF;\n",
        '重复声明改 assign')

#--------------------------------------------------------------------------
# 2) 把 aim_predict 例化搬到 bond_w 声明之后
#    锚点：整段插入文本（与 patch_far_predict.py 里的字符串完全一致）
#--------------------------------------------------------------------------
block = (
    '\n'
    '//-------------------------------------------------------\n'
    '// (9b) 速度预测（lead）：用最近几帧灯心外推「飞镖飞到时灯在哪」\n'
    '//   TRK_EN=0 时喂 raw_*（不加延迟，舵机跟踪要的就是快）；\n'
    '//   TRK_EN=1 时喂跟踪后的值（更稳，但慢 HIT_N 帧 -> 自己权衡）。\n'
    '//   pred_ok=0（历史不足 / 关闭）时输出直接镜像输入，等于不预测。\n'
    '//-------------------------------------------------------\n'
    'aim_predict #(\n'
    '    .AW     (AW    ),\n'
    '    .WIDTH  (IMG_W ),\n'
    '    .HEIGHT (IMG_H )\n'
    ') u_aim_predict (\n'
    '    .clk       (clk       ),\n'
    '    .rst_n     (rst_n     ),\n'
    '    .vsync     (vsync     ),\n'
    '    .en        (pred_on   ),\n'
    '    .raw_valid (TRK_EN ? trk_valid : raw_valid),\n'
    '    .cx        (TRK_EN ? trk_cx    : raw_cx   ),\n'
    '    .cy        (TRK_EN ? trk_cy    : raw_cy   ),\n'
    '    .bw        (bond_w    ),\n'
    '    .aim_h_q8  (aim_h_eff ),\n'
    '    .lead_q4   (lead_q4_eff),\n'
    '    .pcx       (pd_cx     ),\n'
    '    .pcy       (pd_cy     ),\n'
    '    .pay       (pd_ay     ),\n'
    '    .vx_q4     (pd_vx     ),\n'
    '    .vy_q4     (pd_vy     ),\n'
    '    .pred_ok   (pd_ok     ),\n'
    '    .moving    (pd_mov    )\n'
    ');\n'
)
if t.count(block) != 1:
    raise SystemExit('aim_predict 例化块匹配 %d 处（应为 1）' % t.count(block))
t = t.replace(block, '')                     # 先摘掉
t = sub(t,
        "assign aim_y      = aim_y_r;\n",
        "assign aim_y      = aim_y_r;\n" + block,
        'aim_predict 例化搬家')

save(REL, t, enc, crlf, raw)
print('=== 修复完成 ===')
