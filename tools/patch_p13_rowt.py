# -*- coding: utf-8 -*-
"""patch_p13_rowt.py -- row_t 改成有符号（避免「圆外的行被夹到 0 之后凭空多出一个像素」）

 dx^2 <= r2 - dy^2 里，如果 dy^2 > r2，左边应该没有任何像素；
 但把 r2-dy^2 夹到 0 之后，dx=0 那一个像素会因为 `0 <= 0` 被判成命中
 （秒级单测的 syn_bg_gray_v 就是这个：y=302, r=60 -> dy=62 -> 本该全背景）。
 改成 25 位有符号减法 + 有符号比较即可。
"""
import os

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
P = os.path.join(ROOT, 'rtl/syn_target.v')

with open(P, 'rb') as fh:
    raw = fh.read()
t = raw.decode('gbk')
crlf = '\r\n' in t
t = t.replace('\r\n', '\n')

old = ("reg  [23:0] row_t;\n"
       "always @(posedge clk or negedge rst_n) begin\n"
       "    if(!rst_n) row_t <= 24'd0;\n"
       "    else       row_t <= (r2 > {3'b0, dya2}) ? (r2 - {3'b0, dya2}) : 24'd0;\n"
       "end\n")
new = ("//  必须有符号：dy^2 > r2 时 r2-dy^2 是负数 -> 那一行一个像素都不该命中。\n"
       "//  如果夹到 0，dx=0 那一点会因为「0 <= 0」被凭空画出来（实测踩到）。\n"
       "reg signed [24:0] row_t;\n"
       "always @(posedge clk or negedge rst_n) begin\n"
       "    if(!rst_n) row_t <= 25'sd0;\n"
       "    else       row_t <= $signed({1'b0, r2}) - $signed({4'b0, dya2});\n"
       "end\n")
if t.count(old) != 1:
    raise SystemExit('锚点 %d 处' % t.count(old))
t = t.replace(old, new)

old2 = ("//  注意：row_t 是 24 位、dxa2 是 21 位 -> 显式补零再比，最宽也就 24 位\n"
        "assign pix = ({3'b0, dxa2} <= row_t) ? PIX_GREEN : PIX_BG;\n")
new2 = ("//  有符号比较（两边都补零扩到 25 位）\n"
        "assign pix = ($signed({4'b0, dxa2}) <= row_t) ? PIX_GREEN : PIX_BG;\n")
if t.count(old2) != 1:
    raise SystemExit('锚点2 %d 处' % t.count(old2))
t = t.replace(old2, new2)
print('[ok]   row_t 改成 25 位有符号 + 有符号比较')

out = t.replace('\n', '\r\n') if crlf else t
with open(P, 'wb') as fh:
    fh.write(out.encode('gbk'))
with open(P, 'rb') as fh:
    if fh.read().decode('gbk') != out:
        raise SystemExit('**** 回读比对失败 ****')
print('[ok]   rtl/syn_target.v  %d -> %d bytes' % (len(raw), len(out.encode('gbk'))))
