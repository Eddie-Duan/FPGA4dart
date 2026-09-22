# -*- coding: utf-8 -*-
"""_term_probe.py -- probe remaining Taiwan-style terms in project code (ASCII-safe output)."""
import os

ROOT = os.path.dirname(os.path.abspath(__file__))
TERMS = ['致能', '除能', '资料', '实作', '座标', '存取', '频宽', '位元', '类比', '讯框',
         '回圈', '组态', '侦错', '全域', '装置', '网路', '模组', '除错', '门槛', '档案',
         '侦测', '时脉', '暂存器', '遮罩', '脚位', '位址', '预设', '萤幕', '讯号', '影像',
         '阵列', '介面', '连结', '范本', '韧体', '硬体', '软体', '视讯', '撷取', '档案夹']
DIRS = ('rtl', 'sim', 'prj', 'tools')


def decode(b):
    try:
        return b.decode('utf-8')
    except UnicodeDecodeError:
        try:
            return b.decode('gbk')
        except UnicodeDecodeError:
            return None


counts = {t: 0 for t in TERMS}
where = {}
for d in DIRS:
    base = os.path.join(ROOT, d)
    for dirpath, dirnames, filenames in os.walk(base):
        dirnames[:] = [x for x in dirnames if x not in ('xsim.dir', 'webtalk', '__pycache__')]
        for fn in filenames:
            if not fn.lower().endswith(('.v', '.vh', '.sv', '.xdc', '.ucf', '.tcl', '.py')):
                continue
            p = os.path.join(dirpath, fn)
            txt = decode(open(p, 'rb').read())
            if not txt:
                continue
            for t in TERMS:
                n = txt.count(t)
                if n:
                    counts[t] += n
                    where.setdefault(t, []).append('%s x%d' % (os.path.relpath(p, ROOT), n))

for t in TERMS:
    if counts[t]:
        print('%s (%d): %s' % (ascii(t), counts[t], '; '.join(where[t][:6])))
print('done')
