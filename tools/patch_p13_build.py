# -*- coding: utf-8 -*-
"""patch_p13_build.py -- 把 rtl/syn_target.v 加进仿真脚本与 OOC 综合脚本的文件列表
（两个脚本的 read_verilog / xvlog 列表都要手工同步，漏了就会 [Synth 8-439] not found）"""
import os

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def patch(rel, anchor, ins, what, enc):
    p = os.path.join(ROOT, rel)
    with open(p, 'rb') as fh:
        raw = fh.read()
    t = raw.decode(enc)
    crlf = '\r\n' in t
    t = t.replace('\r\n', '\n')
    if ins.strip() in t:
        print('[skip] %s 已有' % what)
        return
    if t.count(anchor) != 1:
        raise SystemExit('%s：锚点 %d 处' % (what, t.count(anchor)))
    t = t.replace(anchor, ins + anchor)
    out = t.replace('\n', '\r\n') if crlf else t
    with open(p, 'wb') as fh:
        fh.write(out.encode(enc))
    with open(p, 'rb') as fh:
        if fh.read().decode(enc) != out:
            raise SystemExit('**** %s 回读比对失败 ****' % rel)
    print('[ok]   %s  %d -> %d bytes' % (rel, len(raw), len(out.encode(enc))))


# 仿真脚本（GBK）
patch('sim/run_vision_sim.bat',
      "  ..\\rtl\\temporal_acc.v ^\n",
      "  ..\\rtl\\syn_target.v ^\n",
      'run_vision_sim.bat 加 syn_target.v', 'gbk')

# OOC 综合脚本（UTF-8 还是 GBK 都按 gbk 试，失败再试 utf-8）
p = os.path.join(ROOT, 'tools/synth_check_vision.tcl')
with open(p, 'rb') as fh:
    raw = fh.read()
enc = 'gbk'
try:
    t = raw.decode('gbk')
except UnicodeDecodeError:
    enc = 'utf-8'
    t = raw.decode('utf-8')
crlf = '\r\n' in t
t = t.replace('\r\n', '\n')
if 'rtl/syn_target.v' in t:
    print('[skip] synth_check_vision.tcl 已有')
else:
    for anchor in ('$rtl/temporal_acc.v \\\n', '$rtl/temporal_acc.v\n'):
        if t.count(anchor) == 1:
            t = t.replace(anchor, '$rtl/syn_target.v \\\n' + anchor)
            out = t.replace('\n', '\r\n') if crlf else t
            with open(p, 'wb') as fh:
                fh.write(out.encode(enc))
            with open(p, 'rb') as fh:
                if fh.read().decode(enc) != out:
                    raise SystemExit('**** 回读比对失败 ****')
            print('[ok]   synth_check_vision.tcl 加 syn_target.v (%d -> %d bytes)'
                  % (len(raw), len(out.encode(enc))))
            break
    else:
        raise SystemExit('synth_check_vision.tcl 找不到 temporal_acc.v 锚点')
