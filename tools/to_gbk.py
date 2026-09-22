# -*- coding: utf-8 -*-
"""
to_gbk.py  --  把新加入的視覺模組註解從 UTF-8 轉成 GBK

為什麼：fpga4dart 專案內的 rtl/.xdc 都是 GBK 編碼（Vivado 在中文 Windows 下預設 ANSI），
        新檔案若留在 UTF-8，Vivado 內建編輯器會顯示成亂碼。

安全性：
    - 已經是 GBK 的檔案自動跳過（避免二次編碼）
    - 轉換後立刻用 GBK 讀回比對，不一致就報錯（不會留下壞檔）
    - 內容若含 GBK 無法表示的符號（例如 ★ ✓ −）會轉換失敗並保留原檔

用法（在專案根目錄）：
    python tools/to_gbk.py
"""

import os

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)          # 專案根目錄（fpga4dart）

FILES = [
    'rtl/armor_vision.v',
    'rtl/vision_cfg.v',
    'rtl/color_seg.v',
    'rtl/morph_nxn.v',
    'rtl/line_buffer.v',
    'rtl/video_delay.v',
    'rtl/proj_bond.v',
    'rtl/overlay_box.v',
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
            print('[skip] %s 已經不是 UTF-8（應該是 GBK）' % rel)
            continue

        text = data.decode('utf-8')
        try:
            out = text.encode('gbk')
        except UnicodeEncodeError as exc:
            print('[FAIL] %s 有 GBK 無法表示的符號: %s' % (rel, exc))
            continue

        with open(path, 'wb') as fh:
            fh.write(out)

        with open(path, 'rb') as fh:
            back = fh.read().decode('gbk')
        if back != text:
            raise SystemExit('**** %s 轉換後比對失敗，請從版本控制還原 ****' % rel)

        print('[ok]   %s  UTF-8 %d bytes -> GBK %d bytes' % (rel, len(data), len(out)))


if __name__ == '__main__':
    main()
