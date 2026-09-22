# -*- coding: utf-8 -*-
"""
check_project_paths.py  --  检查 prj/*.xpr 里引用的文件是否都存在

用途：把 Vivado 专案复制/搬移之后（只复制源代码、不复制 .gen/.runs），
      先确认 .xpr 引用的每个文件都在，避免开 Vivado 才发现少档。

用法（在专案根目录）：
    python tools/check_project_paths.py
"""

import os
import re

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)                       # 专案根目录
XPR  = os.path.join(ROOT, 'prj', 'ov5640_lcd.xpr')

# Vivado 专案内的变数 -> 实际目录
VARS = {
    '$PPRDIR':  os.path.join(ROOT, 'prj'),
    '$PSRCDIR': os.path.join(ROOT, 'prj', 'ov5640_lcd.srcs'),
    '$PGENDIR': os.path.join(ROOT, 'prj', 'ov5640_lcd.gen'),      # 产生出来的，允许不存在
    '$PCACHEDIR': os.path.join(ROOT, 'prj', 'ov5640_lcd.cache'),  # 产生出来的，允许不存在
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
    print('引用文件: %d 个' % len(refs))

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
        print('[OK] 所有引用的文件都存在')
        return

    hard = [m for m in missing if not m[1]]
    soft = [m for m in missing if m[1]]

    for ref, _ in soft:
        print('[gen ] 尚未产生（开 Vivado 后会自动重建）: %s' % ref)
    for ref, _ in hard:
        print('[MISS] 缺少: %s' % ref)

    if hard:
        raise SystemExit('有 %d 个必要文件缺失' % len(hard))
    print('[OK] 源代码文件齐全（仅缺少可重建的产生档）')


if __name__ == '__main__':
    main()
