# -*- coding: utf-8 -*-
"""patch_p14_comment.py -- 把被挤到 trk_on 那行的孤立注释挪回它原本的 tacc_on 行（纯排版，逻辑不变）"""
import os

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
P = os.path.join(ROOT, 'rtl', 'armor_vision.v')

raw = open(P, 'rb').read()
t = raw.decode('gbk')
crlf = '\r\n' in t
t = t.replace('\r\n', '\n')
lines = t.split('\n')

ti = [i for i, l in enumerate(lines) if l.startswith('wire tacc_on')]
ki = [i for i, l in enumerate(lines) if l.startswith('wire trk_on')]
if len(ti) != 1 or len(ki) != 1:
    raise SystemExit('定位失败: tacc_on=%d trk_on=%d' % (len(ti), len(ki)))

i, k = ti[0], ki[0]
kline = lines[k]
mark = 'α-β 跟踪器'
changed = False
# 幂等：已经修过就跳过
if kline.count(mark) == 1:
    tail = kline[kline.index(mark) + len(mark):].strip()
    if tail.startswith('//'):
        lines[k] = kline[:kline.index(mark) + len(mark)].rstrip()
        lines[i] = lines[i].rstrip() + '   ' + tail
        changed = True
        print('[ok] 把 %s 挪回 wire tacc_on 行' % tail)
    else:
        print('[skip] trk_on 行后面没有孤立注释')
else:
    print('[skip] 锚点不是 1 处（%d）' % kline.count(mark))

out = ('\n'.join(lines).replace('\n', '\r\n') if crlf else '\n'.join(lines))
open(P, 'wb').write(out.encode('gbk'))
assert open(P, 'rb').read().decode('gbk') == out, '回读比对失败'
print('[ok]  rtl/armor_vision.v  %d -> %d bytes (changed=%s)' % (len(raw), len(out.encode('gbk')), changed))
