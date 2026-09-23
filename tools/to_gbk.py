# -*- coding: utf-8 -*-
"""
to_gbk.py  --  把新加入的视觉模块注解从 UTF-8 转成 GBK

为什么：fpga4dart 专案内的 rtl/.xdc 都是 GBK 编码（Vivado 在中文 Windows 下默认 ANSI），
        新文件若留在 UTF-8，Vivado 内建编辑器会显示成乱码。

安全性：
    - 已经是 GBK 的文件自动跳过（避免二次编码）
    - 转换后立刻用 GBK 读回比对，不一致就报错（不会留下坏档）
    - 内容若含 GBK 无法表示的符号（例如 ★ ✓ −）会转换失败并保留原档

用法（在专案根目录）：
    python tools/to_gbk.py
"""

import os

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)          # 专案根目录（fpga4dart）

FILES = [
    'rtl/armor_vision.v',
    'rtl/vision_cfg.v',
    'rtl/color_seg.v',
    'rtl/morph_nxn.v',
    'rtl/line_buffer.v',
    'rtl/video_delay.v',
    'rtl/proj_bond.v',
    'rtl/overlay_box.v',
    'rtl/seg_display.v',
    'rtl/key_debounce.v',
    'sim/tb_armor_vision.v',
]


def utf8_ok(data):
    try:
        data.decode('utf-8')
        return True
    except UnicodeDecodeError:
        return False


def main():
    for rel in FILES:
        path = os.path.join(ROOT, rel.replace('/', os.sep))
        if not os.path.isfile(path):
            print('[miss] %s' % rel)
            continue

        with open(path, 'rb') as fh:
            data = fh.read()

        if not utf8_ok(data):
            print('[skip] %s 已经不是 UTF-8（应该是 GBK）' % rel)
            continue

        text = data.decode('utf-8')
        try:
            out = text.encode('gbk')
        except UnicodeEncodeError as exc:
            print('[FAIL] %s 有 GBK 无法表示的符号: %s' % (rel, exc))
            continue

        with open(path, 'wb') as fh:
            fh.write(out)

        with open(path, 'rb') as fh:
            back = fh.read().decode('gbk')
        if back != text:
            raise SystemExit('**** %s 转换后比对失败，请从版本控制还原 ****' % rel)

        print('[ok]   %s  UTF-8 %d bytes -> GBK %d bytes' % (rel, len(data), len(out)))


if __name__ == '__main__':
    main()
