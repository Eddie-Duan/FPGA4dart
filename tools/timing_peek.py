# -*- coding: utf-8 -*-
"""
timing_peek.py -- 从 Vivado 的 timing_summary_routed.rpt 里挑出「有用的那几页」

为什么需要：这个报告动辄几 MB，里面的表是超宽文本行，用 Select-String / grep 看
会变成一堆被截断的乱行。真正要回答的问题只有三个：
    1) 失败的是哪个时钟域 / 哪几条路径？
    2) 关键路径的源 / 目的寄存器在哪个模块？
    3) 延迟主要花在逻辑级数还是布线？

用法（在工程根目录）：
    python tools/timing_peek.py                      # 默认看 impl_1 的报告
    python tools/timing_peek.py <report.rpt>
    python tools/timing_peek.py <report.rpt> --paths 5   # 打印前 5 条违例路径
"""

import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
DEFAULT = os.path.join(ROOT, 'prj', 'ov5640_lcd.runs', 'impl_1',
                       'ov5640_lcd_timing_summary_routed.rpt')

KEEP = ('Slack (', 'Source:', 'Destination:', 'Path Group:', 'Path Type:',
        'Requirement:', 'Data Path Delay:', 'Logic Levels:', 'Clock Path Skew:',
        'Total Derivative:', 'Clock Uncertainty:')


def read(path):
    raw = open(path, 'rb').read()
    for enc in ('utf-8', 'gbk', 'utf-16'):
        try:
            return raw.decode(enc)
        except UnicodeDecodeError:
            continue
    return raw.decode('utf-8', errors='replace')


def block_after(lines, pattern, n, start=0):
    for i in range(start, len(lines)):
        if re.search(pattern, lines[i]):
            return i, lines[i:i + n]
    return -1, []


def main():
    path = DEFAULT
    npaths = 3
    args = sys.argv[1:]
    if '--paths' in args:
        i = args.index('--paths')
        npaths = int(args[i + 1])
        del args[i:i + 2]
    if args:
        path = args[0]
    if not os.path.isfile(path):
        raise SystemExit('找不到报告：%s' % path)

    t = read(path)
    lines = t.split('\n')
    print('报告：%s' % path)
    print('共 %d 行' % len(lines))

    # ---- 1) Design Timing Summary 那张表（只打有数字的行）----
    i, blk = block_after(lines, r'^\s*Design Timing Summary\s*$', 40)
    if i >= 0:
        print('\n=== Design Timing Summary ===')
        for ln in blk:
            s = ln.rstrip()
            if re.search(r'\d+\.\d{3}', s) and 'Clock' not in s:
                print(s[:200])

    # ---- 2) 时钟 / 跨时钟表：只留 WNS 为负的行 ----
    for title in ('Intra Clock Table', 'Inter Clock Table',
                  'Clock Summary', 'Path Group Table'):
        i, blk = block_after(lines, r'^\s*%s\s*$' % title, 60)
        if i < 0:
            continue
        hits = [ln.rstrip()[:200] for ln in blk
                if re.match(r'^\s*\S', ln) and ln.count('.') and '-0\.' in ln]
        if hits:
            print('\n=== %s（负 slack 的行）===' % title)
            for h in hits[:20]:
                print(h)

    # ---- 3) 违例路径的头部 ----
    print('\n=== 违例路径（前 %d 条）===' % npaths)
    shown = 0
    for idx, ln in enumerate(lines):
        if 'Slack (' not in ln or 'VIOLATED' not in ln.upper():
            continue
        if 'Setup' not in ''.join(lines[idx:idx + 8]) and \
           'Hold' not in ''.join(lines[idx:idx + 8]):
            pass
        print('-' * 100)
        for ln2 in lines[idx:idx + 40]:
            s = ln2.rstrip()
            if any(s.strip().startswith(k) for k in KEEP):
                print(s[:200])
            if s.strip().startswith('Data Path Delay:'):
                break
        shown += 1
        if shown >= npaths:
            break
    if shown == 0:
        print('（没有 VIOLATED 的路径？看上面 Design Timing Summary）')


if __name__ == '__main__':
    main()
