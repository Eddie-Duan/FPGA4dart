# -*- coding: utf-8 -*-
"""scan_zh.py -- 扫描工程内所有文本档的编码与中文分布（只读，不改档）

输出 report 到 %TEMP%\\fpga_zh_report.txt（UTF-8），供人工检查。
"""
import os
import sys
import tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
EXTS = {'.v', '.vh', '.sv', '.xdc', '.ucf', '.tcl', '.bat', '.py', '.ps1',
        '.xpr', '.md', '.jou', '.txt', '.json', '.xml'}
SKIP_DIRS = {'xsim.dir', '.git', '.gen', '.runs', '.cache', '.hw', '.sim',
             '.ip_user_files', 'webtalk', '__pycache__'}


def decode(b):
    try:
        return b.decode('utf-8'), 'UTF-8'
    except UnicodeDecodeError:
        pass
    try:
        return b.decode('gbk'), 'GBK'
    except UnicodeDecodeError:
        return None, 'UNKNOWN'


def han_count(t):
    return sum(1 for c in t if '\u4e00' <= c <= '\u9fff')


def main():
    rows = []
    for dirpath, dirnames, filenames in os.walk(ROOT):
        dirnames[:] = [d for d in dirnames if d not in SKIP_DIRS]
        for fn in filenames:
            ext = os.path.splitext(fn)[1].lower()
            if ext not in EXTS:
                continue
            p = os.path.join(dirpath, fn)
            try:
                b = open(p, 'rb').read()
            except OSError as e:
                rows.append((os.path.relpath(p, ROOT), 'ERR', -1, str(e)))
                continue
            txt, enc = decode(b)
            rel = os.path.relpath(p, ROOT)
            if txt is None:
                rows.append((rel, enc, -1, ''))
                continue
            n = han_count(txt)
            nonascii = sum(1 for c in txt if ord(c) > 127)
            gbk_ok = True
            try:
                txt.encode('gbk')
            except UnicodeEncodeError:
                gbk_ok = False
            rows.append((rel, enc, n, 'nonascii=%d gbk_ok=%s' % (nonascii, gbk_ok)))

    rows.sort(key=lambda r: (r[2] <= 0, r[0]))
    lines = ['%-56s %-8s %6s  %s' % ('file', 'enc', 'han', 'note')]
    for rel, enc, n, note in rows:
        lines.append('%-56s %-8s %6d  %s' % (rel, enc, n, note))

    # 顺便报告：含中文的档案（依 han 多寡排序）
    lines.append('')
    lines.append('=== files containing Han characters (by count) ===')
    for rel, enc, n, note in sorted(rows, key=lambda r: -r[2]):
        if n > 0:
            lines.append('%6d  %-8s %s' % (n, enc, rel))

    out = os.path.join(tempfile.gettempdir(), 'fpga_zh_report.txt')
    with open(out, 'w', encoding='utf-8') as f:
        f.write('\n'.join(lines) + '\n')
    print('report written: %s' % out)
    print('files scanned: %d, with Han: %d' % (len(rows), sum(1 for r in rows if r[2] > 0)))


if __name__ == '__main__':
    main()
