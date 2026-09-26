# -*- coding: utf-8 -*-
"""
patch_p13_synperf.py -- 修 syn_target 的时序（OOC 预检 PRECHECK_WNS 从 +6.64 掉到 -2.888）

根因：逐像素路径上串了「两个平方 + 加法 + 比较」（dxa*dxa + dya*dya <= r2），
在 50MHz（20ns）下太长。

修法（圆方程的经典化简）：
    dx^2 + dy^2 <= r2    <=>    dx^2 <= (r2 - dy^2)
`r2 - dy^2` 只跟行有关 -> 用一个寄存器 row_t 逐拍算好（y_cnt 一行内不变，
行间的消隐间隙足够让寄存器跟上），逐像素只剩「一个平方 + 比较」。

注意契约（写进注释 + 秒级单测也跟着改）：换行后要至少过一个时钟，row_t 才跟上
—— 真实光栅的行间消隐天然满足这一点。
"""
import os

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
P = os.path.join(ROOT, 'rtl/syn_target.v')

with open(P, 'rb') as fh:
    raw = fh.read()
t = raw.decode('gbk')
crlf = '\r\n' in t
t = t.replace('\r\n', '\n')

old = ("//  逐像素：|x-cx|^2 + |y-cy|^2 与 r^2 比较（都取绝对值，回避有符号平方的坑）\n"
       "wire signed [AW:0] dxs = $signed({1'b0, x}) - $signed({1'b0, cx_now[AW-1:0]});\n"
       "wire signed [AW:0] dys = $signed({1'b0, y}) - $signed({1'b0, Y_MID});\n"
       "wire        [AW:0] dxa = dxs[AW] ? (~dxs + 1'b1) : dxs;\n"
       "wire        [AW:0] dya = dys[AW] ? (~dys + 1'b1) : dys;\n"
       "wire [2*AW+1:0]    dist2 = dxa*dxa + dya*dya;\n"
       "\n"
       "assign cx  = cx_now[AW-1:0];\n"
       "assign pix = (dist2 <= r2[2*AW+1:0]) ? PIX_GREEN : PIX_BG;\n")

new = ("//  圆方程的经典化简：dx^2 + dy^2 <= r2  <=>  dx^2 <= (r2 - dy^2)\n"
       "//  r2 - dy^2 只跟行有关，用一个寄存器逐拍算好（y_cnt 一行内不变，行间消隐足够跟上）\n"
       "//  -> 逐像素只剩「一个平方 + 一个比较」，50MHz（20ns）下才收得住。\n"
       "//  契约：换行后要过至少一个时钟 row_t 才跟上（真实光栅的行间消隐天然满足）。\n"
       "wire signed [AW:0] dys  = $signed({1'b0, y}) - $signed({1'b0, Y_MID});\n"
       "wire        [AW:0] dya  = dys[AW] ? (~dys + 1'b1) : dys;\n"
       "wire [2*AW+1:0]    dya2 = dya*dya;\n"
       "\n"
       "reg  [23:0] row_t;\n"
       "always @(posedge clk or negedge rst_n) begin\n"
       "    if(!rst_n) row_t <= 24'd0;\n"
       "    else       row_t <= (r2 > {3'b0, dya2}) ? (r2 - {3'b0, dya2}) : 24'd0;\n"
       "end\n"
       "\n"
       "wire signed [AW:0] dxs = $signed({1'b0, x}) - $signed({1'b0, cx_now[AW-1:0]});\n"
       "wire        [AW:0] dxa = dxs[AW] ? (~dxs + 1'b1) : dxs;\n"
       "wire [2*AW+1:0]    dxa2 = dxa*dxa;\n"
       "\n"
       "assign cx  = cx_now[AW-1:0];\n"
       "//  注意：row_t 是 24 位、dxa2 是 21 位 -> 显式补零再比，最宽也就 24 位\n"
       "assign pix = ({3'b0, dxa2} <= row_t) ? PIX_GREEN : PIX_BG;\n")

if t.count(old) != 1:
    raise SystemExit('锚点 %d 处' % t.count(old))
t = t.replace(old, new)
print('[ok]   syn_target: 逐像素只剩一个乘法（row_t 预算 r2-dy^2）')

out = t.replace('\n', '\r\n') if crlf else t
with open(P, 'wb') as fh:
    fh.write(out.encode('gbk'))
with open(P, 'rb') as fh:
    if fh.read().decode('gbk') != out:
        raise SystemExit('**** 回读比对失败 ****')
print('[ok]   rtl/syn_target.v  %d -> %d bytes' % (len(raw), len(out.encode('gbk'))))

# ---- 秒级单测：换行后要给一个时钟（row_t 才跟上）----
P2 = os.path.join(ROOT, 'sim/tb_p13.v')
with open(P2, 'rb') as fh:
    raw2 = fh.read()
t2 = raw2.decode('ascii')
t2 = t2.replace('\r\n', '\n')
pairs = [
    ("        sy_y = 10'd302; sy_x = 10'd400; #1;     // |302-240| = 62 > 60 -> 圆外\n",
     "        sy_y = 10'd302; sy_x = 10'd400;          // |302-240| = 62 > 60 -> 圆外\n"
     "        repeat(2) @(posedge clk);                // row_t 是行级预算寄存器：换行后要过一个时钟\n"),
    ("        sy_y = 10'd240; #1;\n",
     "        sy_y = 10'd240; repeat(2) @(posedge clk);\n"),
    ("        sy_rad = 10'd100; sy_x = 10'd500; #1;\n",
     "        sy_rad = 10'd100; sy_x = 10'd500; repeat(3) @(posedge clk);   // r2 也要一拍\n"),
]
for old2, new2 in pairs:
    if t2.count(old2) != 1:
        raise SystemExit('tb 锚点 %d 处: %r' % (t2.count(old2), old2[:40]))
    t2 = t2.replace(old2, new2)
out2 = t2.replace('\n', '\r\n')
with open(P2, 'wb') as fh:
    fh.write(out2.encode('ascii'))
with open(P2, 'rb') as fh:
    if fh.read().decode('ascii') != out2:
        raise SystemExit('**** tb 回读比对失败 ****')
print('[ok]   sim/tb_p13.v  %d -> %d bytes' % (len(raw2), len(out2.encode('ascii'))))
