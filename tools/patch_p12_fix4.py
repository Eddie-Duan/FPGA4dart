# -*- coding: utf-8 -*-
"""
patch_p12_fix4.py -- 软件强制清零（0x0C bit7）其实没接线

文档/寄存器表写的是「写 1 -> 立即清空累积器」，但 RTL 里 `clr` 只参与了
`byp`（走直通）和写使能，**没有触发清空 FSM** —— 清空 FSM 只由复位启动。
也就是说这个按钮按下去只停一拍累积，RAM 里旧值还在，是典型的「文档写了、代码没接」。

修法：`clr` 也触发清空 FSM（重新从 0 走一圈），走完后自动恢复累积。
代价：清零期间（384000 拍 ≈ 7.7ms）`byp=1`，累积暂时直通 —— 目标检测照常工作。

同时给两个测试台补上「清零」检查（8×4 实例只要 32 拍）：
  清零前 acc=2（够门限），清零后**同一像素再亮一帧必须不够**（acc=1）——
  这样能区分「真清了」和「只是旁路了一拍」。
"""

import os

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)


def load(rel):
    with open(os.path.join(ROOT, rel), 'rb') as fh:
        raw = fh.read()
    t = raw.decode('gbk')
    return raw, t, ('\r\n' in t)


def save(rel, raw, t, crlf, nrep):
    out = t.replace('\n', '\r\n') if crlf else t
    with open(os.path.join(ROOT, rel), 'wb') as fh:
        fh.write(out.encode('gbk'))
    with open(os.path.join(ROOT, rel), 'rb') as fh:
        if fh.read().decode('gbk') != out:
            raise SystemExit('**** %s 回读比对失败 ****' % rel)
    print('[ok]   %s  %d -> %d bytes' % (rel, len(raw), len(out.encode('gbk'))))


# =====================================================================
# 1) RTL：clr 触发清空 FSM
# =====================================================================
rel = 'rtl/temporal_acc.v'
raw, t, crlf = load(rel)
t = t.replace('\r\n', '\n')

old = ("    else if(clr_run) begin\n"
       "        if(clr_adr == CLR_LAST) clr_run <= 1'b0;\n"
       "        else                    clr_adr <= clr_adr + 21'd1;\n"
       "    end\n")
new = ("    else if(clr) begin                  // 软件强制清零：重新走一圈（走完自动恢复累积）\n"
       "        clr_run <= 1'b1;\n"
       "        clr_adr <= 21'd0;\n"
       "    end\n"
       "    else if(clr_run) begin\n"
       "        if(clr_adr == CLR_LAST) clr_run <= 1'b0;\n"
       "        else                    clr_adr <= clr_adr + 21'd1;\n"
       "    end\n")
if t.count(old) != 1:
    raise SystemExit('RTL 清空 FSM 锚点 %d 处' % t.count(old))
t = t.replace(old, new)
print('[ok]   RTL：clr 触发清空 FSM')
save(rel, raw, t, crlf, 1)

# =====================================================================
# 2) 秒级单测：加 clr 检查
# =====================================================================
rel = 'sim/tb_tacc.v'
raw, t, crlf = load(rel)
t = t.replace('\r\n', '\n')

pairs = [
    ("    reg        mask_in = 1'b0;\n",
     "    reg        mask_in = 1'b0;\n    reg        clr     = 1'b0;\n",
     'tb_tacc: 加 clr 寄存器'),
    ("        .clr     (1'b0    ),\n",
     "        .clr     (clr     ),\n",
     'tb_tacc: clr 接到端口'),
    ("        if(err_cnt == 32'd0)\n",
     "        //  software force-clear: the whole RAM must really be wiped (not just bypassed)\n"
     "        @(negedge clk); clr = 1'b1;\n"
     "        @(negedge clk); clr = 1'b0;\n"
     "        repeat(60) @(posedge clk);      // 8x4 = 32 entries to walk through\n"
     "        px(3'd2, 3'd1, 1'b1);\n"
     "        chk(\"clr_wiped\", {31'b0, mask_o}, 32'd0);   // had acc=2 before the clear\n"
     "        px(3'd2, 3'd1, 1'b1);\n"
     "        chk(\"clr_rehit\", {31'b0, mask_o}, 32'd1);\n"
     "\n"
     "        if(err_cnt == 32'd0)\n",
     'tb_tacc: 加 clr_wiped / clr_rehit'),
]
for old, new, what in pairs:
    if t.count(old) != 1:
        raise SystemExit('%s：锚点 %d 处' % (what, t.count(old)))
    t = t.replace(old, new)
    print('[ok]   %s' % what)
save(rel, raw, t, crlf, 3)

# =====================================================================
# 3) 主测试台相位 14：加同样的 clr 检查
# =====================================================================
rel = 'sim/tb_armor_vision.v'
raw, t, crlf = load(rel)
t = t.replace('\r\n', '\n')

pairs = [
    ("reg         ta2_mask = 1'b0;\n",
     "reg         ta2_mask = 1'b0;\nreg         ta2_clr  = 1'b0;\n",
     '主 tb: 加 ta2_clr'),
    ("    .clr     (1'b0     ),\n",
     "    .clr     (ta2_clr  ),\n",
     '主 tb: clr 接到端口'),
    ("    chk(\"tacc_persist\", {31'b0, ta2_masko}, 32'd1);\n",
     "    chk(\"tacc_persist\", {31'b0, ta2_masko}, 32'd1);\n"
     "    //  软件强制清零（0x0C bit7）：整块 RAM 真的被清掉，而不是只旁路一拍\n"
     "    @(negedge clk); ta2_clr = 1'b1;\n"
     "    @(negedge clk); ta2_clr = 1'b0;\n"
     "    repeat(60) @(posedge clk);      // 8x4 = 32 拍清完\n"
     "    ta2_px(3'd2, 3'd1, 1'b1);\n"
     "    chk(\"tacc_clr_wipe\", {31'b0, ta2_masko}, 32'd0);   // 清零前 acc=2\n"
     "    ta2_px(3'd2, 3'd1, 1'b1);\n"
     "    chk(\"tacc_clr_rehit\", {31'b0, ta2_masko}, 32'd1);\n",
     '主 tb: 加 tacc_clr_wipe / tacc_clr_rehit'),
]
for old, new, what in pairs:
    if t.count(old) != 1:
        raise SystemExit('%s：锚点 %d 处' % (what, t.count(old)))
    t = t.replace(old, new)
    print('[ok]   %s' % what)
save(rel, raw, t, crlf, 3)
print('=== 修补 4 完成 ===')
