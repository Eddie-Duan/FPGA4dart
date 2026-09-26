# -*- coding: utf-8 -*-
"""patch_p13_synfix2.py -- 用「行号 + 内容断言」定位替换（多行锚点匹配不可靠时就该这样）"""
import os

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
P = os.path.join(ROOT, 'rtl/syn_target.v')

with open(P, 'rb') as fh:
    raw = fh.read()
t = raw.decode('gbk')
crlf = '\r\n' in t
t = t.replace('\r\n', '\n')
L = t.split('\n')

# ---- (1) 速度立即生效：改 nx/bounce 那三行（55~57，1 基） ----
i = next(k for k, l in enumerate(L) if l.startswith('wire signed [23:0] nx     =') )
assert 'bounce' in L[i + 1] and 'nx_cl' in L[i + 2], L[i:i + 3]
L[i:i + 3] = [
    "//  用「新速度」先试探一次：越界就把速度取反（改 0x0D 立即生效，不拖一帧）",
    "wire signed [23:0] trial  = cx_q4 + spd_s;",
    "wire               flip   = (trial > hi_lim) || (trial < lo_lim);",
    "wire signed [23:0] v_new  = flip ? -spd_s : spd_s;",
    "wire signed [23:0] nx     = cx_q4 + v_new;",
    "wire               bounce = (nx > hi_lim) || (nx < lo_lim);",
    "wire signed [23:0] nx_cl  = bounce ? ((nx > hi_lim) ? hi_lim : lo_lim) : nx;",
]
print('[ok]   速度立即生效 + 碰边反向')

t = '\n'.join(L)

# ---- (2) 位置更新用 v_new ----
old = "        cx_q4 <= nx_cl;\n        vx_q4 <= bounce ? -spd_s : spd_s;\n"
new = "        cx_q4 <= nx_cl;\n        vx_q4 <= v_new;\n"
assert t.count(old) == 1, t.count(old)
t = t.replace(old, new)
print('[ok]   位置用 v_new')

# ---- (3) 加 rad_d 声明 ----
old = "reg        [23:0]  r2    ;       // 半径平方（每帧算一次）\n"
assert t.count(old) == 1, t.count(old)
t = t.replace(old, "reg        [23:0]  r2    ;       // 半径平方\n"
                   "reg  [AW-1:0]      rad_d ;       // 上一拍的半径（检测半径被改）\n")
print('[ok]   加 rad_d')

# ---- (4) r2 跟随 rad 变化 ----
old = ("    if(!rst_n) r2 <= 24'd0;\n"
       "    else if(vsync) r2 <= {14'd0, rad} * {14'd0, rad};\n")
new = ("    if(!rst_n) begin\n"
       "        rad_d <= {AW{1'b0}};\n"
       "        r2    <= 24'd0;\n"
       "    end\n"
       "    else begin\n"
       "        rad_d <= rad;\n"
       "        if(rad != rad_d) r2 <= {14'd0, rad} * {14'd0, rad};\n"
       "    end\n")
assert t.count(old) == 1, t.count(old)
t = t.replace(old, new)
print('[ok]   r2 跟随 rad 变化（复位后第一个周期就有效）')

out = t.replace('\n', '\r\n') if crlf else t
with open(P, 'wb') as fh:
    fh.write(out.encode('gbk'))
with open(P, 'rb') as fh:
    if fh.read().decode('gbk') != out:
        raise SystemExit('**** 回读比对失败 ****')
print('[ok]   rtl/syn_target.v  %d -> %d bytes' % (len(raw), len(out.encode('gbk'))))
