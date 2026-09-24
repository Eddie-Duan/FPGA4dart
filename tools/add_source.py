# -*- coding: utf-8 -*-
"""
add_source.py -- 新增 rtl/*.v 的「一键上户口」：转成 GBK + 注册进 Vivado 工程

为什么需要：
  1) 工程里 rtl/*.v 全部是 GBK（Vivado 在中文 Windows 下的 ANSI）。新文件用编辑器写出
     来时是 UTF-8，Vivado 内建编辑器会显示成乱码 -> 必须转码。
  2) Vivado 的 sources_1 是 .xpr 里写死的 file list。新增 .v 不注册的话，
     综合阶段根本不会编译它（xsim 用 *.v 通配符，所以仿真会通过、综合才炸——很难查）。

用法（在专案根目录）：
    python tools/add_source.py rtl/vision_stat.v              # 转码 + 注册
    python tools/add_source.py vision_stat.v cc_label.v       # 省略 rtl/ 也可以
    python tools/add_source.py --list                         # 列出已注册的 rtl 文件

安全性：
  - 已经是 GBK 的文件自动跳过转码（避免二次编码破坏中文）
  - 转码后立刻回读比对，不一致直接报错退出，不留下坏档
  - 含 GBK 无法表示的字符（★ ✓ − ⚠ 等）会转码失败并保留原档
  - 已注册的 xpr 条目自动跳过（幂等）
"""

import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
XPR = os.path.join(ROOT, 'prj', 'ov5640_lcd.xpr')

#  .xpr 里 sources_1 的插入锚点（与 tools/patch_green.py 一致）
ANCHOR = b'      <File Path="$PSRCDIR/sources_1/ip/mig_7series_0/mig_a.prj">'


def utf8_ok(data):
    try:
        data.decode('utf-8')
        return True
    except UnicodeDecodeError:
        return False


def detect_nl(data):
    return b'\r\n' if b'\r\n' in data else b'\n'


def to_gbk(rel):
    """UTF-8 -> GBK，带回读比对。返回 True 表示写过盘。"""
    path = os.path.join(ROOT, rel.replace('/', os.sep))
    with open(path, 'rb') as fh:
        data = fh.read()

    if not utf8_ok(data):
        return False                      # 已经是 GBK（或其它单字节），跳过

    text = data.decode('utf-8')
    try:
        out = text.encode('gbk')
    except UnicodeEncodeError as exc:
        print('[FAIL] %s 含 GBK 无法表示的字符: %s' % (rel, exc))
        print('       换掉这些字符（★ ✓ − ⚠ 等）后重跑，或用 ASCII 替代。')
        return None

    with open(path, 'wb') as fh:
        fh.write(out)
    with open(path, 'rb') as fh:
        if fh.read().decode('gbk') != text:
            raise SystemExit('**** %s 转码后回读比对失败，请从版本控制还原 ****' % rel)

    print('[gbk]  %s  UTF-8 %d -> GBK %d bytes' % (rel, len(data), len(out)))
    return True


def registered(data, name):
    return (b'$PPRDIR/../rtl/' + name.encode('ascii') + b'"') in data


def register(names):
    with open(XPR, 'rb') as fh:
        data = fh.read()

    if data.count(ANCHOR) != 1:
        raise SystemExit('xpr 找不到唯一的插入锚点，请检查工程结构')

    nl = detect_nl(data)
    todo = [n for n in names if not registered(data, n)]
    if not todo:
        print('[skip] xpr 已注册: %s' % ', '.join(names))
        return

    blocks = b''
    for name in todo:
        blocks += (b'      <File Path="$PPRDIR/../rtl/' + name.encode('ascii') + b'">' + nl +
                   b'        <FileInfo>' + nl +
                   b'          <Attr Name="UsedIn" Val="synthesis"/>' + nl +
                   b'          <Attr Name="UsedIn" Val="implementation"/>' + nl +
                   b'          <Attr Name="UsedIn" Val="simulation"/>' + nl +
                   b'        </FileInfo>' + nl +
                   b'      </File>' + nl)

    with open(XPR, 'wb') as fh:
        fh.write(data.replace(ANCHOR, blocks + ANCHOR))
    print('[xpr]  注册 %d 个新 rtl 文件: %s' % (len(todo), ', '.join(todo)))


def do_list():
    with open(XPR, 'rb') as fh:
        data = fh.read()
    found = []
    pos = 0
    tag = b'$PPRDIR/../rtl/'
    while True:
        i = data.find(tag, pos)
        if i < 0:
            break
        j = data.find(b'"', i)
        found.append(data[i + len(tag):j].decode('ascii'))
        pos = j
    print('xpr 已注册的 rtl 文件（%d）:' % len(found))
    for n in sorted(found):
        print('  %s' % n)


def main():
    args = [a for a in sys.argv[1:] if a != '--list']
    if '--list' in sys.argv:
        do_list()
        return
    if not args:
        raise SystemExit(__doc__)

    names = []
    for a in args:
        a = a.replace('\\', '/')
        if not a.endswith('.v'):
            raise SystemExit('只处理 .v 文件: %s' % a)
        names.append(a if '/' in a else 'rtl/' + a)
        if not os.path.isfile(os.path.join(ROOT, names[-1].replace('/', os.sep))):
            raise SystemExit('文件不存在: %s' % names[-1])

    for rel in names:
        to_gbk(rel)

    register([os.path.basename(n) for n in names])
    print('done.')


if __name__ == '__main__':
    main()
