# -*- coding: utf-8 -*-
"""
patch_p13_regfile.py -- P13：寄存器文件新增 5 个运行时可调参数

  0x0D  SYN_SPD   合成靶标速度（有符号 Q4，px/帧；80 = 5.0 px/帧）
  0x0E  SYN_R     合成靶标半径（像素，默认 60 -> 直径 120px，落在推荐取景范围）
  0x0F  SYN_EN    0 = 用相机（默认）  1 = 用板上合成靶标
  0x10  ST_PAGE   数码管状态页：0 = 正常（阈值/宽度）  1 = 距离/下坠  2 = 面积/填充率  3 = 速度
  0x11  LEAD_AUTO 0 = 提前量用手动 0x0A  1 = 由距离自动算（默认）

reg_file.v 是 UTF-8（唯一一个不是 GBK 的 rtl 文件），所以这里用 utf-8 读写。
"""

import os

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
REL = 'rtl/reg_file.v'

with open(os.path.join(ROOT, REL), 'rb') as fh:
    raw = fh.read()
t = raw.decode('utf-8')
crlf = '\r\n' in t
t = t.replace('\r\n', '\n')

pairs = [
    # ---- 端口 ----
    ("    output reg [7:0]   r_tacc    ,",
     "    output reg [7:0]   r_tacc    ,\n"
     "    output reg [7:0]   r_syn_spd ,   // 0x0D P13 合成靶标速度（有符号 Q4 px/帧）\n"
     "    output reg [7:0]   r_syn_r   ,   // 0x0E P13 合成靶标半径（像素）\n"
     "    output reg [7:0]   r_syn_en  ,   // 0x0F P13 1 = 用合成靶标代替相机\n"
     "    output reg [7:0]   r_st_page ,   // 0x10 P13 数码管状态页\n"
     "    output reg [7:0]   r_lead_auto,  // 0x11 P13 1 = 提前量由距离自动算",
     'reg_file: 新增 5 个输出端口'),

    # ---- 复位值 ----
    ("        r_tacc     <= 8'h02;",
     "        r_tacc     <= 8'h02;\n"
     "        r_syn_spd  <= 8'd80;      // 5.0 px/帧（Q4 = 80）\n"
     "        r_syn_r    <= 8'd60;      // 直径 120px：落在「推荐取景 100~130px」范围内\n"
     "        r_syn_en   <= 8'd0;       // 默认用相机\n"
     "        r_st_page  <= 8'd0;       // 默认正常显示页\n"
     "        r_lead_auto<= 8'd1;       // 默认按距离自动算提前量",
     'reg_file: 复位值'),

    # ---- 地址译码 ----
    ("                                8'h0C: r_tacc     <= data_t;",
     "                                8'h0C: r_tacc     <= data_t;\n"
     "                                8'h0D: r_syn_spd  <= data_t;\n"
     "                                8'h0E: r_syn_r    <= data_t;\n"
     "                                8'h0F: r_syn_en   <= data_t;\n"
     "                                8'h10: r_st_page  <= data_t;\n"
     "                                8'h11: r_lead_auto<= data_t;",
     'reg_file: 地址译码 0x0D~0x11'),
]

for old, new, what in pairs:
    if t.count(old) != 1:
        raise SystemExit('%s：锚点匹配 %d 处（应为 1）' % (what, t.count(old)))
    t = t.replace(old, new)
    print('[ok]   %s' % what)

out = t.replace('\n', '\r\n') if crlf else t
with open(os.path.join(ROOT, REL), 'wb') as fh:
    fh.write(out.encode('utf-8'))
with open(os.path.join(ROOT, REL), 'rb') as fh:
    if fh.read().decode('utf-8') != out:
        raise SystemExit('**** 回读比对失败 ****')
print('[ok]   %s  %d -> %d bytes' % (REL, len(raw), len(out.encode('utf-8'))))
print('=== P13 reg_file 完成 ===')
