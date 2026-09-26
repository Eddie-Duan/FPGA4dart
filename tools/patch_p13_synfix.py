# -*- coding: utf-8 -*-
"""
patch_p13_synfix.py -- 修 syn_target 的两个真 bug（秒级单测抓出来的）

1) r2（半径平方）原来只在 vsync 锁存 -> 复位后第一帧 r2=0，圆根本画不出来
   （测试里 syn_edge_in / syn_radius_big 都失败了）。改成「rad 一变就重算」，
   复位后第一个周期就会算出 r2=3600，不再有启动空窗。
2) 改速度后要等一帧才生效（位置更新用的是上一帧的 vx_q4）-> 现在改成
   「用新速度试探 -> 碰边就取反 -> 再移动」，改 0x0D 立刻生效。
"""
import os

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
P = os.path.join(ROOT, 'rtl/syn_target.v')

with open(P, 'rb') as fh:
    raw = fh.read()
t = raw.decode('gbk')
crlf = '\r\n' in t
t = t.replace('\r\n', '\n')

steps = [
    # (1) 速度：立即生效 + 碰边立即反向
    ("wire signed [23:0] nx     = cx_q4 + vx_q4;\n"
     "wire               bounce = (nx > hi_lim) || (nx < lo_lim);\n"
     "wire signed [23:0] nx_cl  = (nx > hi_lim) ? hi_lim : ((nx < lo_lim) ? lo_lim : nx);\n",
     "//  用「新速度」先试探一次：超出边界就把速度取反（改 0x0D 立即生效，不拖一帧）\n"
     "wire signed [23:0] trial  = cx_q4 + spd_s;\n"
     "wire               flip   = (trial > hi_lim) || (trial < lo_lim);\n"
     "wire signed [23:0] v_new  = flip ? -spd_s : spd_s;\n"
     "wire signed [23:0] nx     = cx_q4 + v_new;\n"
     "wire               bounce = (nx > hi_lim) || (nx < lo_lim);\n"
     "wire signed [23:0] nx_cl  = bounce ? ((nx > hi_lim) ? hi_lim : lo_lim) : nx;\n",
     'syn_target: 速度立即生效 + 碰边反向'),

    ("        cx_q4 <= nx_cl;\n"
     "        vx_q4 <= bounce ? -spd_s : spd_s;\n",
     "        cx_q4 <= nx_cl;\n"
     "        vx_q4 <= v_new;\n",
     'syn_target: 位置用 v_new'),

    # (2) r2：rad 一变就重算（不再只在 vsync 锁存）
    ("reg        [23:0]  r2    ;       // 半径平方（每帧算一次）\n",
     "reg        [23:0]  r2    ;       // 半径平方\n"
     "reg  [AW-1:0]      rad_d ;       // 上一拍的半径，用来检测「半径被改了」\n",
     'syn_target: 加 rad_d'),

    ("//-------------------------------------------------------\n"
     "// 半径平方：每帧更新一次（默认 60 -> 3600）\n"
     "//-------------------------------------------------------\n"
     "always @(posedge clk or negedge rst_n) begin\n"
     "    if(!rst_n) r2 <= 24'd0;\n"
     "    else if(vsync) r2 <= {14'd0, rad} * {14'd0, rad};\n"
     "end\n",
     "//-------------------------------------------------------\n"
     "// 半径平方：rad 一变就重算（复位后第一个周期就算好，不留启动空窗）\n"
     "//-------------------------------------------------------\n"
     "always @(posedge clk or negedge rst_n) begin\n"
     "    if(!rst_n) begin\n"
     "        rad_d <= {AW{1'b0}};\n"
     "        r2    <= 24'd0;\n"
     "    end\n"
     "    else begin\n"
     "        rad_d <= rad;\n"
     "        if(rad != rad_d) r2 <= {14'd0, rad} * {14'd0, rad};\n"
     "    end\n"
     "end\n",
     'syn_target: r2 跟随 rad 变化'),
]

for what, old, new in steps:
    if t.count(old) != 1:
        raise SystemExit('%s：锚点 %d 处' % (what, t.count(old)))
    t = t.replace(old, new)
    print('[ok]   %s' % what)

out = t.replace('\n', '\r\n') if crlf else t
with open(P, 'wb') as fh:
    fh.write(out.encode('gbk'))
with open(P, 'rb') as fh:
    if fh.read().decode('gbk') != out:
        raise SystemExit('**** 回读比对失败 ****')
print('[ok]   rtl/syn_target.v  %d -> %d bytes' % (len(raw), len(out.encode('gbk'))))
