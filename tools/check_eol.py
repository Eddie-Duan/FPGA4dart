# -*- coding: utf-8 -*-
"""
check_eol.py -- 检查 rtl/ 下 GBK 源文件的换行是否干净

背景：create_file 在 Windows 写出的是 CRLF，多行模板字符串里带着 '\r\n'，
      再做「\n -> \r\n」的还原就会产生 '\r\r\n'（多余一个 CR）。
      Verilog 把 CR 当空白，编译器不报错，但文件会越来越脏。

用法：
    python tools/check_eol.py            # 只报告
    python tools/check_eol.py --fix      # 把 '\r\r\n' 压回 '\r\n'（就地修，回读比对）
"""

import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
SCAN = ['rtl', 'sim']


def scan():
    bad = []
    for sub in SCAN:
        d = os.path.join(ROOT, sub)
        if not os.path.isdir(d):
            continue
        for name in sorted(os.listdir(d)):
            if not name.endswith(('.v', '.sv', '.vh', '.svh')):
                continue
            path = os.path.join(d, name)
            with open(path, 'rb') as fh:
                data = fh.read()
            n_lone_cr = data.count(b'\r') - data.count(b'\r\n')
            n_dbl = data.count(b'\r\r\n')
            if n_dbl or n_lone_cr:
                bad.append((os.path.join(sub, name), n_dbl, n_lone_cr, path))
    return bad


def main():
    fix = '--fix' in sys.argv
    bad = scan()
    if not bad:
        print('[ok] rtl/ 与 sim/ 下所有 .v/.sv/.vh 换行干净')
        return

    for rel, n_dbl, n_lone, path in bad:
        print('[!!] %-28s  \\r\\r\\n x %-4d  孤立 \\r x %d' % (rel, n_dbl, n_lone))
        if fix:
            with open(path, 'rb') as fh:
                data = fh.read()
            out = data.replace(b'\r\r\n', b'\r\n')
            with open(path, 'wb') as fh:
                fh.write(out)
            with open(path, 'rb') as fh:
                if fh.read() != out:
                    raise SystemExit('**** %s 修复后比对失败 ****' % rel)
            print('     -> 已修复 %d -> %d bytes' % (len(data), len(out)))

    if not fix:
        print()
        print('加 --fix 就地修复。')


if __name__ == '__main__':
    main()
