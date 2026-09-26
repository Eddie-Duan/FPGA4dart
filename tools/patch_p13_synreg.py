# -*- coding: utf-8 -*-
"""
patch_p13_synreg.py -- syn_target 逐像素输出打一拍（修 OOC 时序 -1.293ns）

根因：`cam_pix = syn_on ? syn_pix : data_v` 把「组合出来的合成像素」和「寄存过的相机像素」
混在一起 —— 相机那路的第一级是寄存器 data_v，合成那路却是从 x_v 直接组合出去的，
于是合成模式下整条下游链路（median -> color_seg -> ... -> blob_track）比相机模式多了一级组合，
实测最差路径 21.05ns（x_v -> syn_target 的乘法 -> ... -> u_blob_track/emit_x0_reg/CE）。

修法：pix 打一拍（合成像素和 data_v 一样从寄存器出发）。
打拍会让图整体左移 1 个像素（一个时钟 = 一个像素），所以比较用的 x 要 +1 抵消：
   第 t 拍算 (x_v=x-1)，第 t+1 拍出现在管线的 x 位置上 —— 等价于「用 x_v 算」，
   于是把 x_v 当成 (x_v-1) 用，即比较 (x_v+1) 与 cx。
"""
import os

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
P = os.path.join(ROOT, 'rtl/syn_target.v')

with open(P, 'rb') as fh:
    raw = fh.read()
t = raw.decode('gbk')
crlf = '\r\n' in t
t = t.replace('\r\n', '\n')

# 1) 端口：pix 从组合改成寄存
old = "    output     [15:0]    pix     ,   // 合成像素（组合输出，与 x/y 同拍）\n"
new = ("    output reg [15:0]    pix     ,   // 合成像素（打一拍；x 比较时 +1 抵消这拍延迟）\n")
assert t.count(old) == 1, t.count(old)
t = t.replace(old, new)
print('[ok]   pix 改成 reg')

# 2) x 比较用 x+1（抵消打拍带来的 1 像素左移）
old = "wire signed [AW:0] dxs = $signed({1'b0, x}) - $signed({1'b0, cx_now[AW-1:0]});\n"
new = ("//  打拍让图左移 1 像素 -> 比较时把 x 加 1 抵消回去（见文件头说明）\n"
       "wire [AW:0]        x_eff = {1'b0, x} + 1'b1;\n"
       "wire signed [AW:0] dxs  = $signed(x_eff) - $signed({1'b0, cx_now[AW-1:0]});\n")
assert t.count(old) == 1, t.count(old)
t = t.replace(old, new)
print('[ok]   x 比较 +1 抵消打拍')

# 3) pix 寄存器化
old = "assign cx  = cx_now[AW-1:0];\n"
new = ("assign cx  = cx_now[AW-1:0];\n"
       "\n"
       "always @(posedge clk or negedge rst_n) begin\n"
       "    if(!rst_n) pix <= PIX_BG;\n"
       "    else       pix <= ($signed({4'b0, dxa2}) <= row_t) ? PIX_GREEN : PIX_BG;\n"
       "end\n")
assert t.count(old) == 1, t.count(old)
t = t.replace(old, new)

old = "//  有符号比较（两边都补零扩到 25 位）\nassign pix = ($signed({4'b0, dxa2}) <= row_t) ? PIX_GREEN : PIX_BG;\n"
assert t.count(old) == 1, t.count(old)
t = t.replace(old, "//  有符号比较（两边都补零扩到 25 位）放在上面的时序块里\n")
print('[ok]   pix 寄存器化')

out = t.replace('\n', '\r\n') if crlf else t
with open(P, 'wb') as fh:
    fh.write(out.encode('gbk'))
with open(P, 'rb') as fh:
    if fh.read().decode('gbk') != out:
        raise SystemExit('**** 回读比对失败 ****')
print('[ok]   rtl/syn_target.v  %d -> %d bytes' % (len(raw), len(out.encode('gbk'))))
