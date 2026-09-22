# -*- coding: utf-8 -*-
"""
check_project_paths.py  --  檢查 prj/*.xpr 裡引用的檔案是否都存在

用途：把 Vivado 專案複製/搬移之後（只複製原始碼、不複製 .gen/.runs），
      先確認 .xpr 引用的每個檔案都在，避免開 Vivado 才發現少檔。

用法（在專案根目錄）：
    python tools/check_project_paths.py
"""

import os
import re

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)                       # 專案根目錄
XPR  = os.path.join(ROOT, 'prj', 'ov5640_lcd.xpr')

# Vivado 專案內的變數 -> 實際目錄
VARS = {
    '$PPRDIR':  os.path.join(ROOT, 'prj'),
    '$PSRCDIR': os.path.join(ROOT, 'prj', 'ov5640_lcd.srcs'),
    '$PGENDIR': os.path.join(ROOT, 'prj', 'ov5640_lcd.gen'),      # 產生出來的，允許不存在
    '$PCACHEDIR': os.path.join(ROOT, 'prj', 'ov5640_lcd.cache'),  # 產生出來的，允許不存在
    '$PRUNDIR': os.path.join(ROOT, 'prj', 'ov5640_lcd.runs'),     # 跑完才有
}

GENERATED = ('$PGENDIR', '$PCACHEDIR', '$PRUNDIR')


def main():
    if not os.path.isfile(XPR):
        raise SystemExit('找不到 %s' % XPR)

    with open(XPR, 'r', encoding='utf-8', errors='replace') as fh:
        text = fh.read()

    refs = re.findall(r'<File Path="([^"]+)"', text)
    print('xpr     : %s' % XPR)
    print('引用檔案: %d 個' % len(refs))

    missing = []
    for ref in refs:
        path = ref
        for var, real in VARS.items():
            if path.startswith(var):
                path = real + path[len(var):]
                break
        path = path.replace('/', os.sep)
        if not os.path.isfile(path):
            missing.append((ref, any(ref.startswith(g) for g in GENERATED)))

    if not missing:
        print('[OK] 所有引用的檔案都存在')
        return

    hard = [m for m in missing if not m[1]]
    soft = [m for m in missing if m[1]]

    for ref, _ in soft:
        print('[gen ] 尚未產生（開 Vivado 後會自動重建）: %s' % ref)
    for ref, _ in hard:
        print('[MISS] 缺少: %s' % ref)

    if hard:
        raise SystemExit('有 %d 個必要檔案缺失' % len(hard))
    print('[OK] 原始碼檔案齊全（僅缺少可重建的產生檔）')


if __name__ == '__main__':
    main()
