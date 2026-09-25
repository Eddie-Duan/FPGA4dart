# -*- coding: utf-8 -*-
"""
patch_p11_fix2.py -- 修「8 位实际端口接 10 位形式端口 -> 高位悬空成 z -> X 扩散」

症状：主测试台 4 个像素检查抓到 X（0x0000XX0X），但目标检测全部正常。
探针（sim/tb_probe.v）显示：
    实例内部 ring_t = 0xz02      <- 高 2 位是 z，不是 0！
    rr = 100 正常，但 r_in/r_ou = x -> on_ring = x -> draw = x -> 显示通路全 X

根因（很值得记一辈子）：
    Verilog 里「实际信号比形式端口窄」时 **不会零扩展**，形式端口的高位是
    未连接（高阻 z），参与运算就变 X。
    xvlog 会警告：[VRFC 10-3091] actual bit length 8 differs from formal bit length 10
    —— 这条警告之前被「只筛 ERROR」漏掉了，结果花了半小时定位。

修法：把 eff 中间信号做成和端口一样宽（显式补零）。
（pct_eff / drop_sc_eff 是 8->8，不用改。）
"""

import os

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
REL = 'rtl/armor_vision.v'

with open(os.path.join(ROOT, REL), 'rb') as fh:
    raw = fh.read()
t = raw.decode('gbk')
crlf = '\r\n' in t
t = t.replace('\r\n', '\n')

pairs = [
    ("wire [7:0]    ring_t_eff     ;   // 0x06\n",
     "wire [AW-1:0] ring_t_eff     ;   // 0x06（必须和端口同宽，否则高位悬空成 z）\n",
     'ring_t_eff 声明'),
    ("wire [7:0]    gate_eff       ;   // 0x08\n",
     "wire [AW-1:0] gate_eff       ;   // 0x08（同上）\n",
     'gate_eff 声明'),
    ("assign ring_t_eff  = reg_written ? rf_ring_t : RING_T[7:0];\n",
     "assign ring_t_eff  = reg_written ? {{(AW-8){1'b0}}, rf_ring_t} : RING_T[AW-1:0];\n",
     'ring_t_eff 赋值'),
    ("assign gate_eff    = reg_written ? rf_gate   : GATE[7:0];\n",
     "assign gate_eff    = reg_written ? {{(AW-8){1'b0}}, rf_gate}   : GATE[AW-1:0];\n",
     'gate_eff 赋值'),
]

for old, new, what in pairs:
    if t.count(old) != 1:
        raise SystemExit('%s：锚点匹配 %d 处（应为 1）' % (what, t.count(old)))
    t = t.replace(old, new)

#  顺便把 overlay 例化处的注释写清楚「为什么 eff 要撑到 AW 位」
t = t.replace("    .ring_t(ring_t_eff),\n",
              "    .ring_t(ring_t_eff),   // 注意：ring_t_eff 是 AW 位（窄了高位会悬空）\n")

out = t.replace('\n', '\r\n') if crlf else t
with open(os.path.join(ROOT, REL), 'wb') as fh:
    fh.write(out.encode('gbk'))
with open(os.path.join(ROOT, REL), 'rb') as fh:
    if fh.read().decode('gbk') != out:
        raise SystemExit('**** 回读比对失败 ****')
print('[ok]   %s  %d -> %d bytes' % (REL, len(raw), len(out.encode('gbk'))))
