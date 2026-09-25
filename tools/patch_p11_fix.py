# -*- coding: utf-8 -*-
"""patch_p11_fix.py -- 修 armor_vision.v 里 4 个 eff 信号被声明两次（xvlog 直接报错）"""

import os

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
REL = 'rtl/armor_vision.v'

with open(os.path.join(ROOT, REL), 'rb') as fh:
    raw = fh.read()
t = raw.decode('gbk')
crlf = '\r\n' in t
t = t.replace('\r\n', '\n')

old = ("wire [7:0]    ring_t_eff = reg_written ? rf_ring_t : RING_T[7:0];\n"
       "wire [7:0]    gate_eff   = reg_written ? rf_gate   : GATE[7:0];\n"
       "wire [7:0]    pct_eff    = reg_written ? rf_pct    : ADAPT_PCT[7:0];\n"
       "wire [7:0]    drop_sc_eff= reg_written ? rf_drop_sc        : DROP_SCALE_DEF;\n")
new = ("assign ring_t_eff  = reg_written ? rf_ring_t : RING_T[7:0];\n"
       "assign gate_eff    = reg_written ? rf_gate   : GATE[7:0];\n"
       "assign pct_eff     = reg_written ? rf_pct    : ADAPT_PCT[7:0];\n"
       "assign drop_sc_eff = reg_written ? rf_drop_sc : DROP_SCALE_DEF;\n")
if t.count(old) != 1:
    raise SystemExit('锚点匹配 %d 处（应为 1）' % t.count(old))
t = t.replace(old, new)

out = t.replace('\n', '\r\n') if crlf else t
with open(os.path.join(ROOT, REL), 'wb') as fh:
    fh.write(out.encode('gbk'))
with open(os.path.join(ROOT, REL), 'rb') as fh:
    if fh.read().decode('gbk') != out:
        raise SystemExit('**** 回读比对失败 ****')
print('[ok]   %s  %d -> %d bytes' % (REL, len(raw), len(out.encode('gbk'))))
