# -*- coding: utf-8 -*-
"""
patch_p11_ports.py -- 把 RING_T / GATE / ADAPT_PCT 从 parameter 改成运行时输入

背景：reg_file 早就有 0x06(RING_T) / 0x08(GATE) / 0x09(ADAPT_PCT) 三个地址，
但 armor_vision 里只有 wire 声明、没接进任何子模块 —— 也就是「文档写了、代码没接」
（和当年 0x05 rf_aim_h、以及本次 0x03/0x04 是同一类坑）。补上之后 P2 的
「运行时改参数、免重新综合」才真的成立。

改动：
  rtl/overlay_box.v  parameter RING_T  -> input [AW-1:0] ring_t
  rtl/track_ab.v     parameter GATE    -> input [AW-1:0] gate
  rtl/chroma_hist.v  parameter [7:0] PCT -> input [7:0] pct

三个文件的例化点（armor_vision / tb）在后面的脚本里一起改。
GBK 字节级改 + 回读比对。
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
            return len(raw), raw.decode(enc).replace('\r\n', '\n'), enc, ('\r\n' in raw.decode(enc))
        except UnicodeDecodeError:
            continue
    raise SystemExit('%s 编码未知' % rel)


def save(rel, text, enc, crlf, old_len):
    out = text.replace('\n', '\r\n') if crlf else text
    data = out.encode(enc)
    with open(os.path.join(ROOT, rel), 'wb') as fh:
        fh.write(data)
    with open(os.path.join(ROOT, rel), 'rb') as fh:
        if fh.read().decode(enc) != out:
            raise SystemExit('**** %s 回读比对失败 ****' % rel)
    print('[ok]   %-24s %s  %d -> %d bytes' % (rel, enc, old_len, len(data)))


def sub(t, old, new, what):
    if t.count(old) != 1:
        raise SystemExit('%s：锚点匹配 %d 处（应为 1）' % (what, t.count(old)))
    return t.replace(old, new)


def resub(t, pat, new, what):
    new_t, n = re.subn(pat, new, t, count=1, flags=re.S)
    if n != 1:
        raise SystemExit('%s：锚点匹配 %d 处（应为 1）' % (what, n))
    return new_t


#==========================================================================
# 1) overlay_box.v：圆环宽度改成运行时输入
#==========================================================================
rel = 'rtl/overlay_box.v'
raw, t, enc, crlf = load(rel)
if 'input      [AW-1:0]  ring_t' in t:
    print('[skip] %s 已打过补丁' % rel)
else:
    t = resub(t, r"    parameter RING_T  = 2 ,[^\n]*\n", '', 'overlay_box 删参数')
    t = sub(t, "    input      [AW-1:0]  pvx   ,",
            "    input      [AW-1:0]  ring_t ,   // 圆环宽度（像素，运行时可变；UART 0x06）\n"
            "    input      [AW-1:0]  pvx   ,", 'overlay_box 加端口')
    t = sub(t, "wire [AW:0]  r_in = (rr > RING_T) ? (rr - RING_T) : {(AW+1){1'b0}};\n"
               "wire [AW:0]  r_ou = rr + RING_T;",
            "wire [AW:0]  r_in = (rr > {1'b0, ring_t}) ? (rr - {1'b0, ring_t}) : {(AW+1){1'b0}};\n"
            "wire [AW:0]  r_ou = rr + {1'b0, ring_t};",
            'overlay_box 用端口')
    save(rel, t, enc, crlf, raw)

#==========================================================================
# 2) track_ab.v：门控半径改成运行时输入
#==========================================================================
rel = 'rtl/track_ab.v'
raw, t, enc, crlf = load(rel)
if 'input      [AW-1:0] gate' in t:
    print('[skip] %s 已打过补丁' % rel)
else:
    t = resub(t, r"    parameter GATE     = 96     ,[^\n]*\n", '', 'track_ab 删参数')
    t = sub(t, "    input                 raw_valid  ,",
            "    input      [AW-1:0]   gate       ,   // 门控半径（像素，运行时可变；UART 0x08）\n"
            "    input                 raw_valid  ,", 'track_ab 加端口')
    t = sub(t, "wire signed [AW+2:0] gate_s = GATE;",
            "wire signed [AW+2:0] gate_s = $signed({1'b0, gate});",
            'track_ab 用端口')
    save(rel, t, enc, crlf, raw)

#==========================================================================
# 3) chroma_hist.v：前景占比改成运行时输入
#==========================================================================
rel = 'rtl/chroma_hist.v'
raw, t, enc, crlf = load(rel)
if 'input      [7:0]  pct' in t:
    print('[skip] %s 已打过补丁' % rel)
else:
    t = resub(t, r"    parameter \[7:0\] PCT       = 8'd15  ,[^\n]*\n", '', 'chroma_hist 删参数')
    t = sub(t, "    input              en         ,   // ADAPT_EN",
            "    input      [7:0]   pct        ,   // 前景占比 %（运行时可变；UART 0x09）\n"
            "    input              en         ,   // ADAPT_EN", 'chroma_hist 加端口')
    t = sub(t, "                    thr_cnt  <= (total * PCT) / 8'd100;",
            "                    thr_cnt  <= (total * pct) / 8'd100;",
            'chroma_hist 用端口')
    save(rel, t, enc, crlf, raw)

print('=== 端口改造完成 ===')
