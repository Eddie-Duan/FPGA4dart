# -*- coding: utf-8 -*-
"""
patch_p12_fix5.py -- 关闭时不要读那块大 BRAM（仿真速度）

现象：加上 temporal_acc 之后，全量仿真从 ~8 分钟变成 ~16 分钟（每帧 384000 个像素
各做一次 384000 项数组的读访问，xsim 的数组访问是最贵的一类操作）。

修法：读也加上使能判断 `if(de && en)` —— en=0（默认关闭）时根本不碰 BRAM，
走 byp 直通（功能与原来完全一致），仿真速度立刻回到从前。

对综合无影响：读使能变成 (de && en)，仍然是一个普通使能，BRAM 照常推断
（`symth_check` 里会看到 BRAM 数不变）。
"""

import os

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
REL = 'rtl/temporal_acc.v'

with open(os.path.join(ROOT, REL), 'rb') as fh:
    raw = fh.read()
t = raw.decode('gbk')
crlf = '\r\n' in t
t = t.replace('\r\n', '\n')

old = "        if(de) acc_q <= acc_mem[adr_nx];   // BRAM 同步读：下一拍出数\n"
new = ("        //  读也使能判断：关闭时完全不碰这块大 RAM（xsim 的数组访问很贵，\n"
       "        //  每帧 384000 次会把仿真时间翻倍）；开启时行为不变。\n"
       "        if(de && en) acc_q <= acc_mem[adr_nx];   // BRAM 同步读：下一拍出数\n")

if t.count(old) != 1:
    raise SystemExit('锚点 %d 处（应为 1）' % t.count(old))
t = t.replace(old, new)
print('[ok]   读使能改为 de && en')

out = t.replace('\n', '\r\n') if crlf else t
with open(os.path.join(ROOT, REL), 'wb') as fh:
    fh.write(out.encode('gbk'))
with open(os.path.join(ROOT, REL), 'rb') as fh:
    if fh.read().decode('gbk') != out:
        raise SystemExit('**** 回读比对失败 ****')
print('[ok]   %s  %d -> %d bytes' % (REL, len(raw), len(out.encode('gbk'))))
