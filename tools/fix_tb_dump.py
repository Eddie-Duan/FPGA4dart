# -*- coding: utf-8 -*-
"""
fix_tb_dump.py -- 修 925/928 行

上一次用 re.sub 替换时，替换串里的字面 `\n` 被正则引擎当成换行展开了，
把 Verilog 字符串写成了跨行 -> 语法错误。
这里用 str.replace（不处理转义）修回来，并删掉一条已过期的注释。
"""

import os

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
REL = 'sim/tb_armor_vision.v'

bad = (
    '    $write("\n'
    '  raw_frame2:");\n'
    '    for(uk2 = 34; uk2 < 68; uk2 = uk2 + 1) $write(" %02x", ur_b[uk2]);\n'
    '    $write("\n'
    '");\n'
)
good = (
    '    $write("\\n  raw_frame2:");\n'
    '    for(uk2 = 34; uk2 < 68; uk2 = uk2 + 1) $write(" %02x", ur_b[uk2]);\n'
    '    $write("\\n");\n'
)

with open(os.path.join(ROOT, REL), 'rb') as fh:
    raw = fh.read()
t = raw.decode('gbk')
crlf = '\r\n' in t
t = t.replace('\r\n', '\n')

if t.count(bad) != 1:
    raise SystemExit('锚点坏块匹配 %d 处（应为 1）' % t.count(bad))
t = t.replace(bad, good)
print('[ok]   修回 raw_frame2 / 收尾 $write')

stale = '    //  CRC 期望值是 Python 独立算的（不是从收到的数据反推）\n'
if t.count(stale) == 1:
    t = t.replace(stale, '')
    print('[ok]   删掉过期的 CRC 魔数注释')

out = t.replace('\n', '\r\n') if crlf else t
with open(os.path.join(ROOT, REL), 'wb') as fh:
    fh.write(out.encode('gbk'))
with open(os.path.join(ROOT, REL), 'rb') as fh:
    if fh.read().decode('gbk') != out:
        raise SystemExit('**** 回读比对失败 ****')
print('[ok]   %s  %d -> %d bytes' % (REL, len(raw), len(out.encode('gbk'))))
