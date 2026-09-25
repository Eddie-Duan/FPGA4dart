# -*- coding: utf-8 -*-
"""
patch_p11_tb.py -- 测试台补 P11：v3 帧（34 字节 + CRC16）+ 弹道单测

1) 独立 result_frame 实例的参数补上 P11 字段（dist/drop/fx/fy）
2) UART 接收监视器：24 -> 34 字节，并核对 **CRC16**（期望值是 Python 独立算的）
3) 新增相位 13：ballistic 单元测试（宽度 -> 距离 / 下坠 / 最终瞄准点）
4) 主实例也补两项：u_armor_vision.bl_dist_cm / bl_drop_px（w=199~201 时的期望区间）

GBK 字节级改 + 回读比对。
"""

import os

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
REL = 'sim/tb_armor_vision.v'


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
    print('[ok]   %-28s %s  %d -> %d bytes' % (rel, enc, old_len, len(data)))


def sub(t, old, new, what):
    if t.count(old) != 1:
        raise SystemExit('%s：锚点匹配 %d 处（应为 1）' % (what, t.count(old)))
    return t.replace(old, new)


#==========================================================================
# 期望帧（和 rtl/result_frame.v 的字节布局一一对应，独立算 CRC16）
#==========================================================================
def crc16_ccitt(data):
    crc = 0xFFFF
    for byte in data:
        for i in range(8):
            msb = (crc >> 15) ^ ((byte >> (7 - i)) & 1)
            crc = (crc << 1) & 0xFFFF
            if msb:
                crc ^= 0x1021
    return crc


payload = {2: 0xBB, 3: 0x01, 4: 0x98, 5: 0x00, 6: 0xF8, 7: 0x01, 8: 0x98,
           9: 0x00, 10: 0xC6, 11: 0xC9, 12: 0xFA, 13: 0xC8, 14: 0x01,
           15: 0x00, 16: 0x60, 17: 0x00, 18: 0x00, 19: 0x01, 20: 0xB8,
           21: 0x00, 22: 0xF8, 23: 0x01, 24: 0xF9, 25: 0x00, 26: 0x9F,
           27: 0x01, 28: 0x98, 29: 0x00, 30: 0xB2, 31: 0x00}
crc_exp = crc16_ccitt(bytes(payload[i] for i in range(2, 32)))
print('独立算出的期望 CRC16 = 0x%04X' % crc_exp)

raw, t, enc, crlf = load(REL)
if 'bl_d_cm' in t:
    print('[skip] %s 已打过补丁' % REL)
    raise SystemExit(0)

#==========================================================================
# 1) u_rf_test 补 P11 端口
#==========================================================================
t = sub(t,
        "    .px         (10'd440   ),\n"
        "    .py         (10'd248   ),\n"
        "    .txd        (rf_txd    )\n",
        "    .px         (10'd440   ),\n"
        "    .py         (10'd248   ),\n"
        "    //  P11 弹道字段：w=201 -> dist=70cm drop=22px（表值，见 tools/gen_ballistic_lut.py）\n"
        "    .dist_ok    (1'b1      ),\n"
        "    .dist_cm    (16'd505   ),\n"
        "    .drop_px    (16'd159   ),\n"
        "    .fx         (10'd408   ),\n"
        "    .fy         (10'd178   ),\n"
        "    .txd        (rf_txd    )\n",
        'u_rf_test 端口')

#==========================================================================
# 2) 监视器：24 -> 34 字节
#==========================================================================
t = sub(t, "reg  [7:0]  ur_b [0:23];", "reg  [7:0]  ur_b [0:33];", '监视器数组')
t = sub(t,
        "            if(ur_n < 6'd24) begin\n"
        "                ur_b[ur_n] <= ur_sh;\n"
        "                ur_n <= ur_n + 6'd1;\n"
        "                if(ur_n == 6'd23) ur_done <= 1'b1;  // 第一帧收满 24 字节就冻结\n",
        "            if(ur_n < 6'd34) begin\n"
        "                ur_b[ur_n] <= ur_sh;\n"
        "                ur_n <= ur_n + 6'd1;\n"
        "                if(ur_n == 6'd33) ur_done <= 1'b1;  // 第一帧收满 34 字节就冻结\n",
        '监视器长度')

#==========================================================================
# 3) 相位 12 的检查换成 v3
#==========================================================================
old12 = (
    "    chk(\"uart_nbytes\", {26'd0, ur_n}, 32'd24);\n"
    "    chk(\"uart_hdr0\",   {24'd0, ur_b[0]},  32'hA5);\n"
    "    chk(\"uart_hdr1\",   {24'd0, ur_b[1]},  32'h5A);\n"
    "    chk(\"uart_flags\",  {24'd0, ur_b[2]},  32'hB3);   // v2 标志 + pred/moving/adapt/valid\n"
    "    chk(\"uart_cx\",     ({22'b0, ur_b[3]} << 8) | {24'd0, ur_b[4]}, 32'd408);\n"
    "    chk(\"uart_cy\",     ({22'b0, ur_b[5]} << 8) | {24'd0, ur_b[6]}, 32'd248);\n"
    "    chk(\"uart_ay\",     ({22'b0, ur_b[9]} << 8) | {24'd0, ur_b[10]}, 32'd198);\n"
    "    chk(\"uart_w\",      {24'd0, ur_b[11]}, 32'd201);\n"
    "    chk(\"uart_area7\",  {24'd0, ur_b[12]}, 32'd250);\n"
    "    chk(\"uart_fill\",   {24'd0, ur_b[13]}, 32'd200);\n"
    "    chk(\"uart_vx\",     ({22'b0, ur_b[15]} << 8) | {24'd0, ur_b[16]}, 32'd96);\n"
    "    chk(\"uart_vy\",     ({22'b0, ur_b[17]} << 8) | {24'd0, ur_b[18]}, 32'd0);\n"
    "    chk(\"uart_px\",     ({22'b0, ur_b[19]} << 8) | {24'd0, ur_b[20]}, 32'd440);\n"
    "    chk(\"uart_py\",     ({22'b0, ur_b[21]} << 8) | {24'd0, ur_b[22]}, 32'd248);\n"
    "    chk(\"uart_chk\",    {24'd0, ur_chk_calc(1'b0)}, 32'h56);   // Python 独立算的期望值\n"
)
new12 = (
    "    chk(\"uart_nbytes\", {26'd0, ur_n}, 32'd34);\n"
    "    chk(\"uart_hdr0\",   {24'd0, ur_b[0]},  32'hA5);\n"
    "    chk(\"uart_hdr1\",   {24'd0, ur_b[1]},  32'h5A);\n"
    "    chk(\"uart_flags\",  {24'd0, ur_b[2]},  32'hBB);   // 扩展帧+dist_ok+pred+moving+adapt+valid\n"
    "    chk(\"uart_cx\",     ({22'b0, ur_b[3]} << 8) | {24'd0, ur_b[4]}, 32'd408);\n"
    "    chk(\"uart_cy\",     ({22'b0, ur_b[5]} << 8) | {24'd0, ur_b[6]}, 32'd248);\n"
    "    chk(\"uart_ay\",     ({22'b0, ur_b[9]} << 8) | {24'd0, ur_b[10]}, 32'd198);\n"
    "    chk(\"uart_w\",      {24'd0, ur_b[11]}, 32'd201);\n"
    "    chk(\"uart_area7\",  {24'd0, ur_b[12]}, 32'd250);\n"
    "    chk(\"uart_fill\",   {24'd0, ur_b[13]}, 32'd200);\n"
    "    chk(\"uart_vx\",     ({22'b0, ur_b[15]} << 8) | {24'd0, ur_b[16]}, 32'd96);\n"
    "    chk(\"uart_vy\",     ({22'b0, ur_b[17]} << 8) | {24'd0, ur_b[18]}, 32'd0);\n"
    "    chk(\"uart_px\",     ({22'b0, ur_b[19]} << 8) | {24'd0, ur_b[20]}, 32'd440);\n"
    "    chk(\"uart_py\",     ({22'b0, ur_b[21]} << 8) | {24'd0, ur_b[22]}, 32'd248);\n"
    "    //  P11 新增：距离 / 下坠 / 最终瞄准点\n"
    "    chk(\"uart_dist\",   ({22'b0, ur_b[23]} << 8) | {24'd0, ur_b[24]}, 32'd505);\n"
    "    chk(\"uart_drop\",   ({22'b0, ur_b[25]} << 8) | {24'd0, ur_b[26]}, 32'd159);\n"
    "    chk(\"uart_fx\",     ({22'b0, ur_b[27]} << 8) | {24'd0, ur_b[28]}, 32'd408);\n"
    "    chk(\"uart_fy\",     ({22'b0, ur_b[29]} << 8) | {24'd0, ur_b[30]}, 32'd178);\n"
    "    chk(\"uart_seq\",    {24'd0, ur_b[31]}, 32'd0);     // 第一帧序号 = 0\n"
    "    chk(\"uart_crc\",    ({22'b0, ur_b[32]} << 8) | {24'd0, ur_b[33]}, 32'h%04X);\n"
    "    //  CRC 期望值是 Python 独立算的（不是从收到的数据反推）\n"
) % crc_exp
t = sub(t, old12, new12, '相位12检查')

#==========================================================================
# 4) 弹道单测实例（放 udp 之前，和 track_ab 单测一个风格）
#==========================================================================
t = sub(t,
        "//  ---- P11 弹道单测 ----\n" if False else
        "//  115200 @ 25MHz = 217 拍/位；起始位下降沿后等 1.5 位再每 217 拍采一次\n",
        "//  ---- P11 弹道单测 ----\n"
        "//  宽度 -> 距离 / 下坠 / 最终瞄准点；表值由 tools/gen_ballistic_lut.py 算出\n"
        "reg         bl_vsync = 1'b0;\n"
        "reg  [10:0] bl_bw    = 11'd100;\n"
        "reg  [9:0]  bl_pcx   = 10'd300;\n"
        "reg  [9:0]  bl_pcy   = 10'd248;\n"
        "reg  [7:0]  bl_scale = 8'd255;      // 255 = x1.0（基准弹速 20m/s）\n"
        "wire [15:0] bl_d_cm, bl_d_px;\n"
        "wire [9:0]  bl_fx, bl_fy;\n"
        "wire        bl_ok_t;\n"
        "\n"
        "ballistic #(.AW(10), .WIDTH(800), .HEIGHT(480)) u_bal_test (\n"
        "    .clk        (clk      ),\n"
        "    .rst_n      (rst_n    ),\n"
        "    .vsync      (bl_vsync ),\n"
        "    .en         (1'b1     ),\n"
        "    .raw_valid  (1'b1     ),\n"
        "    .bw         (bl_bw    ),\n"
        "    .aim_h_q8   (16'd64   ),\n"
        "    .pcx        (bl_pcx   ),\n"
        "    .pcy        (bl_pcy   ),\n"
        "    .drop_scale (bl_scale ),\n"
        "    .dist_cm    (bl_d_cm  ),\n"
        "    .drop_px    (bl_d_px  ),\n"
        "    .fx         (bl_fx    ),\n"
        "    .fy         (bl_fy    ),\n"
        "    .dist_ok    (bl_ok_t  )\n"
        ");\n"
        "\n"
        "//  115200 @ 25MHz = 217 拍/位；起始位下降沿后等 1.5 位再每 217 拍采一次\n",
        '弹道单测实例')

#  弹道帧脉冲任务（在 negedge 改激励，避免和 posedge 抢 active 区域）
t = sub(t,
        "initial begin\n"
        "    $display(\"=======================================================\");\n",
        "//  给弹道单测打一拍 vsync（真实帧边界时序：下降沿后再等一拍才是 frame_end）\n"
        "task bl_frame;\n"
        "    begin\n"
        "        @(negedge clk);\n"
        "        bl_vsync = 1'b1;\n"
        "        repeat(4) @(posedge clk);\n"
        "        @(negedge clk);\n"
        "        bl_vsync = 1'b0;\n"
        "        repeat(4) @(posedge clk);\n"
        "    end\n"
        "endtask\n"
        "\n"
        "initial begin\n"
        "    $display(\"=======================================================\");\n",
        '弹道帧任务')

#==========================================================================
# 5) 相位 13 + 主实例的距离/下坠检查
#==========================================================================
phase13 = (
    "    //=====================================================\n"
    "    $display(\"---- phase 13 : ballistic (distance + drop) unit test ----\");\n"
    "    //=====================================================\n"
    "    //  宽度 100 -> 距离 141cm、下坠 45px；pcy=248 - (100*64/256=25) - 45 = 178\n"
    "    bl_bw = 11'd100;\n"
    "    bl_frame();\n"
    "    chk(\"bal_ok\",      {31'b0, bl_ok_t}, 32'd1);\n"
    "    chk(\"bal_dist_w100\", {16'd0, bl_d_cm}, 32'd141);\n"
    "    chk(\"bal_drop_w100\", {16'd0, bl_d_px}, 32'd45);\n"
    "    chk(\"bal_fy_w100\",   {22'd0, bl_fy},   32'd178);\n"
    "    chk(\"bal_fx_w100\",   {22'd0, bl_fx},   32'd300);\n"
    "\n"
    "    //  宽度 201 -> 距离 70cm、下坠 22px；fy = 248 - 50 - 22 = 176\n"
    "    bl_bw = 11'd201;\n"
    "    bl_frame();\n"
    "    chk(\"bal_dist_w201\", {16'd0, bl_d_cm}, 32'd70);\n"
    "    chk(\"bal_drop_w201\", {16'd0, bl_d_px}, 32'd22);\n"
    "    chk(\"bal_fy_w201\",   {22'd0, bl_fy},   32'd176);\n"
    "\n"
    "    //  弹速修正：写 163 (=25m/s, 164/256=0.64) -> 下坠 22*164/256 = 14\n"
    "    bl_scale = 8'd163;\n"
    "    bl_frame();\n"
    "    chk(\"bal_drop_v25\",  {16'd0, bl_d_px}, 32'd14);\n"
    "    chk(\"bal_fy_v25\",    {22'd0, bl_fy},   32'd184);\n"
    "    bl_scale = 8'd255;\n"
    "\n"
    "    //  主实例（灯宽 199~201）也要给出合理的距离/下坠：dist 69~72cm、drop 21~23px\n"
    "    chk(\"main_dist_ok\", {31'b0, u_armor_vision.bl_ok}, 32'd1);\n"
    "    chk_range(\"main_dist\", u_armor_vision.bl_dist_cm, 32'd69, 32'd72);\n"
    "    chk_range(\"main_drop\", u_armor_vision.bl_drop_px, 32'd21, 32'd23);\n"
    "\n"
)
t = sub(t,
        "    if(err_cnt == 32'd0)\n"
        "        $display(\"==== ALL CHECKS PASSED ====\");\n",
        phase13 +
        "    if(err_cnt == 32'd0)\n"
        "        $display(\"==== ALL CHECKS PASSED ====\");\n",
        '相位13')

save(REL, t, enc, crlf, raw)
print('=== 测试台 P11 补丁完成 ===')
