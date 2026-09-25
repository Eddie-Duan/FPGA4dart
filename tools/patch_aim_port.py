# -*- coding: utf-8 -*-
"""
patch_aim_port.py -- 把 blob_track 的 AIM_H_Q8 从 parameter 改成 input 端口

原因：Vivado/xvlog 报 `'aim_h_eff' is not a constant` —— parameter 只能用常量
覆盖，没法接运行时寄存器（UART 0x05）。

改成 input [15:0] aim_h_q8 之后：
  - armor_vision 侧可以写 `.aim_h_q8(aim_h_eff)`，0x05 的微调真的生效；
  - 默认值仍由 armor_vision 的 parameter [15:0] AIM_H_Q8 = 16'd372 提供。
"""
import os
import re

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)


def load(rel):
    with open(os.path.join(ROOT, rel), 'rb') as fh:
        raw = fh.read()
    for enc in ('gbk', 'utf-8'):
        try:
            t = raw.decode(enc)
            break
        except UnicodeDecodeError:
            continue
    else:
        raise SystemExit('%s 既不是 GBK 也不是 UTF-8' % rel)
    crlf = '\r\n' in t
    return len(raw), t.replace('\r\n', '\n'), enc, crlf


def save(rel, text, enc, crlf, old_len):
    path = os.path.join(ROOT, rel)
    out = text.replace('\n', '\r\n') if crlf else text
    data = out.encode(enc)
    with open(path, 'wb') as fh:
        fh.write(data)
    with open(path, 'rb') as fh:
        if fh.read().decode(enc) != out:
            raise SystemExit('**** %s 回读比对失败 ****' % rel)
    print('[ok]   %-28s %s  %d -> %d bytes' % (rel, enc, old_len, len(data)))


def sub1(text, old, new, what):
    n = text.count(old)
    if n != 1:
        raise SystemExit('%s：锚点匹配 %d 处（应为 1）\n%s' % (what, n, old[:200]))
    return text.replace(old, new)


#--------------------------------------------------------------- blob_track.v
rel = 'rtl/blob_track.v'
raw, t, enc, crlf = load(rel)
if 'input [15:0] aim_h_q8' in t:
    print('[skip] %s 已改过' % rel)
else:
    # 删掉 parameter 那一行（它是最后一个 parameter，行尾没有逗号）
    pat = re.compile(r"^[ \t]*parameter \[15:0\] AIM_H_Q8[^\n]*\n", re.M)
    if len(pat.findall(t)) != 1:
        raise SystemExit('parameter 行匹配 %d 处（应为 1）' % len(pat.findall(t)))
    t = pat.sub('', t, count=1)

    # 在 mask 端口之后加一个 16bit 输入
    t = sub1(t,
             "    input                 mask          ,",
             "    input                 mask          ,   // 二值掩码\n"
             "    input      [15:0]     aim_h_q8      ,   // 瞄准点偏移 = 宽度 x aim_h_q8/256（Q0.8，\n"
             "                                             // 运行时可变，由 UART 0x05 / parameter 给）",
             'blob_track mask 端口')

    t = sub1(t, "wire [2*AW+8:0] up_full = bw_w * AIM_H_Q8;",
             "wire [2*AW+8:0] up_full = bw_w * aim_h_q8;",
             'blob_track up_full')
    save(rel, t, enc, crlf, raw)

#-------------------------------------------------------------- armor_vision.v
rel = 'rtl/armor_vision.v'
raw, t, enc, crlf = load(rel)
if '.aim_h_q8 (' in t:
    print('[skip] %s 已改过' % rel)
else:
    t = sub1(t, ".AIM_H_Q8 (aim_h_eff )", ".aim_h_q8 (aim_h_eff )", 'armor_vision 实例连接')
    save(rel, t, enc, crlf, raw)

#------------------------------------------------------------- tb_armor_vision.v
rel = 'sim/tb_armor_vision.v'
raw, t, enc, crlf = load(rel)
if '.aim_h_q8 (' in t:
    print('[skip] %s 已改过' % rel)
else:
    t = sub1(t, ".AIM_H_Q8 (16'd372 )", ".aim_h_q8 (16'd372 )", 'tb 372 实例连接')
    save(rel, t, enc, crlf, raw)

print('\n完成。')
