# -*- coding: utf-8 -*-
"""
check_xpr_sources.py -- 对比「磁盘上的 rtl/*.v」与「工程 .xpr 里登记的」

为什么需要它：综合报 [Synth 8-439] module 'xxx' not found 的唯一原因就是
「文件不在工程的源文件列表里」。而 .xpr 是**文本 XML**，用 string.count('xxx.v')
去搜是不可靠的（别处出现的名字也会被算上，我就被这个坑过一次）——
必须按 <File Path=".../rtl/xxx.v"> 这样的**条目**来解析。

用法：
    python tools/check_xpr_sources.py            # 只报告
    python tools/check_xpr_sources.py --add      # 缺的自动补进 .xpr（Vivado 关着时才有效！）

注意：Vivado GUI 开着时，它保存工程会用**内存里的列表**覆盖 .xpr，
外部补的条目会被静默抹掉 —— 那种情况只能在 Tcl Console 里跑
    source {<repo>/tools/add_sources_vivado.tcl}
"""
import glob
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
XPR = os.path.join(ROOT, 'prj/ov5640_lcd.xpr')

with open(XPR, 'rb') as fh:
    raw = fh.read()
text = raw.decode('utf-8', errors='replace')

inproj = set(re.findall(r'<File Path="[^"]*?/rtl/([A-Za-z0-9_]+\.v)"', text))
disk = set(os.path.basename(p) for p in glob.glob(os.path.join(ROOT, 'rtl', '*.v')))

missing = sorted(disk - inproj)
extra = sorted(inproj - disk)

print('工程 .xpr 里登记的 rtl 文件 : %d' % len(inproj))
print('磁盘 rtl/*.v            : %d' % len(disk))
print('缺（在磁盘、不在工程）   : %s' % (missing if missing else '(无)'))
print('多（在工程、不在磁盘）   : %s' % (extra if extra else '(无)'))

if not missing:
    print('== 一致：可以 Run Synthesis ==')
    raise SystemExit(0)

if '--add' not in sys.argv:
    print('== 有缺失：加 --add 补进 .xpr（Vivado 必须关着），或在 Tcl Console 里跑 add_sources_vivado.tcl')
    raise SystemExit(1)

# 复刻 Vivado 的条目写法：<File Path="$PPRDIR/../rtl/xxx.v"> + 三个 UsedIn 属性
tmpl = ('      <File Path="$PPRDIR/../rtl/%s">\n'
        '        <FileInfo>\n'
        '          <Attr Name="UsedIn" Val="synthesis"/>\n'
        '          <Attr Name="UsedIn" Val="implementation"/>\n'
        '          <Attr Name="UsedIn" Val="simulation"/>\n'
        '        </FileInfo>\n'
        '      </File>\n')

# 插在 armor_vision.v 之后（它一定在列表里，且属于同一个 fileset）
anchor_i = text.find('/rtl/armor_vision.v')
if anchor_i < 0:
    raise SystemExit('找不到 armor_vision.v 的条目，无法定位插入点')
end = text.find('</File>', anchor_i)
if end < 0:
    raise SystemExit('找不到 armor_vision.v 条目的结尾')
ins = end + len('</File>') + 1
new_text = text[:ins] + ''.join(tmpl % n for n in missing) + text[ins:]

with open(XPR, 'wb') as fh:
    fh.write(new_text.encode('utf-8'))
with open(XPR, 'rb') as fh:
    back = fh.read().decode('utf-8', errors='replace')
if back != new_text:
    raise SystemExit('**** .xpr 回读比对失败 ****')

print('== 已补进 .xpr：%s ==' % ', '.join(missing))
print('   提醒：Vivado GUI 若开着，请改用 Tcl Console 里的 add_sources_vivado.tcl')
