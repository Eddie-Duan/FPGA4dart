# -*- coding: utf-8 -*-
"""
patch_p12_fix3.py -- 修 result_frame 的「发送中被重复锁存」致命 bug

现象（由新的软件 CRC 对拍抓出来）：
  收到的帧 byte31(seq)=0x0D，但它的 CRC 却是 seq=0 那一帧的 CRC（0x8B12）；
  第二帧 byte31=0x1C(=28)，CRC 也是 seq=15 那一帧的（0x7AFD）。
  也就是说：**同一帧里，seq 和 CRC 来自不同的帧**。

根因：
  `wire tx_now = frame_tick && (divcnt == TX_DIV - 1);` 是「电平型」触发，
  而负载锁存块写的是 `else if(tx_now) begin ... b[31] <= seq; seq <= seq+1; end`，
  **没有判 FSM 状态**。一帧的发送时间（34 字节 @115200 = 240 + 34*2170 ≈ 74,000 拍）
  远大于 frame_tick 周期（5,000 拍）—— 发送过程中 tx_now 又高了十几次，
  于是负载被重复锁存、seq 被多加了十几次（实测差 15 = 74000/5000）。
  CRC 是在帧头那一次锁存后算好的（之后冻结），传出去的 seq 却是后来又锁存的 ->
  接收端按 CRC 校验必然丢帧；更糟的是，真实工程里 cx/cy/w 每帧都在变，
  中途重复锁存会把两帧的数据混成一份（测试台输入是常量，所以只暴露了 seq 这一项）。

修法：负载只允许在「帧起始」那一拍锁存 —— 加上 `state == S_IDLE` 判断。
S_IDLE 在 tx_now 那一拍本来就会跳到 S_CRC，所以两者同拍，CRC 仍然用的是新负载。
"""

import os

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
REL = 'rtl/result_frame.v'

with open(os.path.join(ROOT, REL), 'rb') as fh:
    raw = fh.read()
t = raw.decode('gbk')
crlf = '\r\n' in t
t = t.replace('\r\n', '\n')

old = "    else if(tx_now) begin\n"
new = ("    //  只在「帧起始」那一拍锁存：tx_now 是电平型触发，一帧的发送时间（约 74,000 拍 @115200、\n"
       "    //  34 字节）远大于 frame_tick 周期，不判 state 就会在发送途中重复锁存 ->\n"
       "    //  传出去的 seq 与 CRC 对不上、接收端必然丢帧；真实工程里每帧变化的 cx/cy/w\n"
       "    //  还会被中途更新，把两帧内容混成一帧。\n"
       "    else if(tx_now && (state == S_IDLE)) begin\n")

if t.count(old) != 1:
    raise SystemExit('锚点匹配 %d 处（应为 1）' % t.count(old))
t = t.replace(old, new)
print('[ok]   负载锁存改为仅在 S_IDLE 那一拍')

out = t.replace('\n', '\r\n') if crlf else t
with open(os.path.join(ROOT, REL), 'wb') as fh:
    fh.write(out.encode('gbk'))
with open(os.path.join(ROOT, REL), 'rb') as fh:
    if fh.read().decode('gbk') != out:
        raise SystemExit('**** 回读比对失败 ****')
print('[ok]   %s  %d -> %d bytes' % (REL, len(raw), len(out.encode('gbk'))))
print('=== 修补 3 完成 ===')
