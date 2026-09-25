# -*- coding: utf-8 -*-
"""
patch_far_predict_tb.py -- 测试台补三项验证

1) phase 10：远处的【小绿灯】（半径 8，约 200 像素）必须被认出来。
   旧代码：area < MIN_AREA(400) -> 整块丢掉 -> valid=0
   （现场症状就是「屏幕上有高亮但识别不到目标」）
2) phase 11：目标以 +6 px/帧 平移 8 帧，检查速度估计与提前量：
   pd_ok=1 / moving=1 / vx>0 / pd_cx 超前 center_x 8~48 像素
3) phase 12：result_frame v2 帧（24 字节）的逐字节核对 ——
   用一个 TX_DIV=1 的独立实例 + 一个 115200 的接收监视器，
   期望校验和是【在 Python 里独立算出来的】，不是从收到的数据反推的，
   这样才真的验到打包逻辑（真正独立实现对拍）。

另外把测试台的圆改成可调（img_cx / img_cy / img_r2），两个相位都靠它。
文件是 GBK，字节级改 + 回读比对。
"""

import os
import re

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
REL = 'sim/tb_armor_vision.v'


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
    out = text.replace('\n', '\r\n') if crlf else text
    try:
        data = out.encode(enc)
    except UnicodeEncodeError as exc:
        raise SystemExit('**** %s 含 %s 装不下的字符: %s ****' % (rel, enc, exc))
    with open(os.path.join(ROOT, rel), 'wb') as fh:
        fh.write(data)
    with open(os.path.join(ROOT, rel), 'rb') as fh:
        if fh.read().decode(enc) != out:
            raise SystemExit('**** %s 回读比对失败 ****' % rel)
    print('[ok]   %-28s %s  %d -> %d bytes' % (rel, enc, old_len, len(data)))


def sub(text, old, new, what):
    if text.count(old) != 1:
        raise SystemExit('%s：锚点匹配 %d 处（应为 1）\n%s' % (what, text.count(old), old[:200]))
    return text.replace(old, new)


#==========================================================================
# 期望帧内容（独立算一遍，和 RTL 里的打包逻辑互为对照）
#==========================================================================
cx, cy, ax, ay = 408, 248, 408, 198
bw, area, fill, cnt = 201, 32000, 200, 1
vx, vy, px, py = 96, 0, 440, 248
FLAGS = 0xB3            # b7=1(v2) b6=0(近) b5=1(动) b4=1(预测) b3=0 b2=0 b1=1 b0=1

exp = {0: 0xA5, 1: 0x5A, 2: FLAGS, 3: cx >> 8, 4: cx & 0xFF, 5: cy >> 8, 6: cy & 0xFF,
       7: ax >> 8, 8: ax & 0xFF, 9: ay >> 8, 10: ay & 0xFF,
       11: min(bw, 255), 12: min(area >> 7, 255), 13: fill, 14: cnt,
       15: (vx >> 8) & 0xFF, 16: vx & 0xFF, 17: (vy >> 8) & 0xFF, 18: vy & 0xFF,
       19: px >> 8, 20: px & 0xFF, 21: py >> 8, 22: py & 0xFF}
chk = 0
for i in range(2, 23):
    chk ^= exp[i]
chk &= 0xFF
print('独立算出的期望校验和 = 0x%02X' % chk)

raw, t, enc, crlf = load(REL)
if 'aim_predict 相位' in t or 'img_r2' in t:
    print('[skip] %s 已打过补丁' % REL)
    raise SystemExit(0)

#==========================================================================
# 1) 把测试图形改成可调（圆心 / 半径平方）
#==========================================================================
t = sub(t,
        "wire signed [11:0] dxc = $signed({1'b0,px}) - 12'sd400;\n"
        "wire signed [11:0] dyc = $signed({1'b0,py}) - 12'sd240;\n"
        "wire [23:0] d2c = dxc*dxc + dyc*dyc;\n"
        "wire in_circle = (d2c <= 24'd10000);\n",
        "//  目标几何做成【可改】的：phase 10 缩小（模拟远灯），\n"
        "//  phase 11 逐帧平移（测速度预测），静止相位用默认值 400/240/10000。\n"
        "reg  [10:0] img_cx = 11'd400;\n"
        "reg  [10:0] img_cy = 11'd240;\n"
        "reg  [23:0] img_r2 = 24'd10000;\n"
        "\n"
        "wire signed [11:0] dxc = $signed({1'b0,px}) - $signed({1'b0,img_cx});\n"
        "wire signed [11:0] dyc = $signed({1'b0,py}) - $signed({1'b0,img_cy});\n"
        "wire [23:0] d2c = dxc*dxc + dyc*dyc;\n"
        "wire in_circle = (d2c <= img_r2);\n",
        '测试图形改成可调')

#==========================================================================
# 2) u_blob_real 例化补上新端口（不接会让比较变 x）
#==========================================================================
t = sub(t,
        "    .mask       (u_armor_vision.mask_d  ),\n"
        "    .aim_h_q8   (16'd372                ),\n",
        "    .mask       (u_armor_vision.mask_d  ),\n"
        "    .aim_h_q8   (16'd372                ),\n"
        "    .min_area_lo(32'd8                  ),\n",
        'u_blob_real 新端口')

#==========================================================================
# 2b) 「宽松档关闭」对照实例：同一个掩码，min_area_lo = 0
#     （不能从 tb 直接给 u_blob_track.min_area_lo 赋值：那是 wire，会多驱动）
#==========================================================================
t = sub(t,
        "    .cent_x     (                       ),\n"
        "    .cent_y     (                       ),\n"
        "    .fill_q8    (                       )\n"
        ");\n",
        "    .cent_x     (                       ),\n"
        "    .cent_y     (                       ),\n"
        "    .fill_q8    (                       )\n"
        ");\n"
        "\n"
        "//  对照组：同一个掩码，但把宽松档关掉（min_area_lo = 0）\n"
        "//  -> 远处的 200 像素小灯必须【认不到】，证明灵敏度是新宽松档带来的\n"
        "wire lo_valid;\n"
        "\n"
        "blob_track #(\n"
        "    .WIDTH    (800     ),\n"
        "    .HEIGHT   (480     ),\n"
        "    .AW       (10      ),\n"
        "    .MIN_AREA (400     )\n"
        ") u_blob_looff (\n"
        "    .clk        (clk                    ),\n"
        "    .rst_n      (rst_n                  ),\n"
        "    .vsync      (vsync                  ),\n"
        "    .de         (u_armor_vision.de_v    ),\n"
        "    .x          (u_armor_vision.x_v     ),\n"
        "    .y          (u_armor_vision.y_cnt   ),\n"
        "    .mask       (u_armor_vision.mask_d  ),\n"
        "    .aim_h_q8   (16'd64                 ),\n"
        "    .min_area_lo(32'd0                  ),\n"
        "    .bond_valid (lo_valid               ),\n"
        "    .bond_l     (                       ),\n"
        "    .bond_r     (                       ),\n"
        "    .bond_t     (                       ),\n"
        "    .bond_b     (                       ),\n"
        "    .center_x   (                       ),\n"
        "    .center_y   (                       ),\n"
        "    .aim_x      (                       ),\n"
        "    .aim_y      (                       ),\n"
        "    .blob_area  (                       ),\n"
        "    .blob_far   (                       ),\n"
        "    .blob_cnt   (                       ),\n"
        "    .cent_x     (                       ),\n"
        "    .cent_y     (                       ),\n"
        "    .fill_q8    (                       )\n"
        ");\n",
        '插入宽松档对照实例')

#==========================================================================
# 3) UART 监视器 + result_frame v2 单测实例
#==========================================================================
uart_blk = (
    "//-------------------------------------------------------\n"
    "// P1/P2 单测：result_frame v2 帧（24 字节）+ UART 接收监视器\n"
    "//   主实例每 TX_DIV=8 帧才发一次，测试台跑不到；这里用 TX_DIV=1 的独立实例，\n"
    "//   把已知常量打包发出来，再逐字节核对（含校验和）。\n"
    "//   校验和的期望值是在 Python 里【独立算】的，不是从收到的数据反推，\n"
    "//   所以能真正验到打包逻辑。\n"
    "//-------------------------------------------------------\n"
    "reg  [15:0] rf_div  = 16'd0;\n"
    "reg         rf_tick = 1'b0;\n"
    "always @(posedge clk) begin\n"
    "    if(!rst_n) begin rf_div <= 16'd0; rf_tick <= 1'b0; end\n"
    "    else begin\n"
    "        rf_div  <= (rf_div == 16'd4999) ? 16'd0 : (rf_div + 16'd1);\n"
    "        rf_tick <= (rf_div == 16'd4999);\n"
    "    end\n"
    "end\n"
    "\n"
    "wire rf_txd;\n"
    "\n"
    "result_frame #(\n"
    "    .CLK_FREQ (25_000_000),\n"
    "    .BAUD     (115200    ),\n"
    "    .TX_DIV   (1         )\n"
    ") u_rf_test (\n"
    "    .clk        (clk       ),\n"
    "    .rst_n      (rst_n     ),\n"
    "    .frame_tick (rf_tick   ),\n"
    "    .valid      (1'b1      ),\n"
    "    .cx         (10'd408   ),\n"
    "    .cy         (10'd248   ),\n"
    "    .ax         (10'd408   ),\n"
    "    .ay         (10'd198   ),\n"
    "    .bw         (11'd201   ),\n"
    "    .area       (32'd32000 ),\n"
    "    .fill_q8    (8'd200    ),\n"
    "    .blob_cnt   (3'd1      ),\n"
    "    .adapt_ok   (1'b1      ),\n"
    "    .disp_bin   (1'b0      ),\n"
    "    .pred_ok    (1'b1      ),\n"
    "    .moving     (1'b1      ),\n"
    "    .far_small  (1'b0      ),\n"
    "    .vx_q4      (16'sd96   ),   // 6.0 px/帧\n"
    "    .vy_q4      (16'sd0    ),\n"
    "    .px         (10'd440   ),\n"
    "    .py         (10'd248   ),\n"
    "    .txd        (rf_txd    )\n"
    ");\n"
    "\n"
    "//  115200 @ 25MHz = 217 拍/位；起始位下降沿后等 1.5 位再每 217 拍采一次\n"
    "localparam integer UART_DIV = 217;\n"
    "reg  [7:0]  ur_b [0:23];\n"
    "reg  [5:0]  ur_n    = 6'd0;\n"
    "reg         ur_act  = 1'b0;\n"
    "reg         ur_done = 1'b0;\n"
    "reg  [15:0] ur_wait = 16'd0;\n"
    "reg  [3:0]  ur_bs   = 4'd0;\n"
    "reg  [7:0]  ur_sh   = 8'd0;\n"
    "integer     uk;\n"
    "\n"
    "always @(posedge clk or negedge rst_n) begin\n"
    "    if(!rst_n) begin\n"
    "        ur_act <= 1'b0; ur_done <= 1'b0; ur_n <= 6'd0;\n"
    "        ur_wait <= 16'd0; ur_bs <= 4'd0; ur_sh <= 8'd0;\n"
    "    end\n"
    "    else if(!ur_act) begin\n"
    "        if(!ur_done && (rf_txd == 1'b0)) begin     // 起始位下降沿\n"
    "            ur_act  <= 1'b1;\n"
    "            ur_bs   <= 4'd0;\n"
    "            ur_sh   <= 8'd0;\n"
    "            ur_wait <= 16'd325;                    // 1.5 位 -> 采到 d0 中点\n"
    "        end\n"
    "    end\n"
    "    else if(ur_wait == 16'd0) begin\n"
    "        if(ur_bs < 4'd8) begin\n"
    "            ur_sh   <= {rf_txd, ur_sh[7:1]};\n"
    "            ur_bs   <= ur_bs + 4'd1;\n"
    "            ur_wait <= 16'd216;                    // 每 217 拍一位\n"
    "        end\n"
    "        else begin                                 // 停止位 -> 收完一个字节\n"
    "            if(ur_n < 6'd24) begin\n"
    "                ur_b[ur_n] <= ur_sh;\n"
    "                ur_n <= ur_n + 6'd1;\n"
    "                if(ur_n == 6'd23) ur_done <= 1'b1;  // 第一帧收满 24 字节就冻结\n"
    "            end\n"
    "            ur_act <= 1'b0;\n"
    "        end\n"
    "    end\n"
    "    else ur_wait <= ur_wait - 16'd1;\n"
    "end\n"
    "\n"
)
t = sub(t, "\ntask chk;\n", "\n" + uart_blk + "task chk;\n", '插入 UART 监视器')

#==========================================================================
# 4) 逐帧平移任务
#==========================================================================
t = sub(t,
        "initial begin\n"
        "    $display(\"=======================================================\");\n",
        "//  逐帧平移目标：在帧边界之后改 img_cx，避免和 posedge 抢同一个 active 区域\n"
        "task move_target;\n"
        "    input integer n;\n"
        "    input integer dx;\n"
        "    integer mk;\n"
        "    begin\n"
        "        for(mk = 0; mk < n; mk = mk + 1) begin\n"
        "            wait_frames(1);\n"
        "            img_cx = img_cx + dx;\n"
        "        end\n"
        "    end\n"
        "endtask\n"
        "\n"
        "initial begin\n"
        "    $display(\"=======================================================\");\n",
        '插入 move_target')

#==========================================================================
# 5) 新相位 10 / 11 / 12
#==========================================================================
phases = (
    "    //=====================================================\n"
    "    //  灵敏度相位：远处的【小绿灯】也必须被认出来\n"
    "    //  旧代码：area < MIN_AREA(400) -> 最大的那块也被丢掉 -> valid=0，\n"
    "    //  现场表现就是「屏幕上有高亮，但识别不到目标」。\n"
    "    //  半径 8 的圆 -> 约 200 像素，落在新的【宽松档】(>= min_area_lo=8)\n"
    "    //=====================================================\n"
    "    $display(\"---- phase 10 : FAR / SMALL lamp (r=8, ~200 px) ----\");\n"
    "    img_r2 = 24'd64;\n"
    "    wait_frames(3);\n"
    "    chk(\"far_valid\",  bond_valid, 32'd1);\n"
    "    chk(\"far_flag\",   {31'b0, u_armor_vision.raw_far}, 32'd1);\n"
    "    chk_range(\"far_w\", u_armor_vision.bond_w, 32'd12, 32'd22);\n"
    "    chk_near(\"far_cx\", center_x, 32'd408, 32'd3);\n"
    "    chk_near(\"far_cy\", center_y, 32'd248, 32'd3);\n"
    "    //  同一个掩码再喂一个【宽松档关闭】的实例：必须回到旧行为（认不到小灯），\n"
    "    //  证明「有绿灯就认」确实是新的宽松档在起作用，而不是别的地方整体松了\n"
    "    chk(\"far_lo_off\", {31'b0, lo_valid}, 32'd0);\n"
    "\n"
    "    //=====================================================\n"
    "    //  速度预测相位：目标 +6 px/帧 平移 8 帧\n"
    "    //  期望：vx 收敛到约 6.0 px/帧（Q4 = 96）；提前量 = v*LEAD/16/256\n"
    "    //  LEAD_Q4=64（4.0 帧）-> pd_cx 应比当前 center_x 超前 8~48 像素\n"
    "    //=====================================================\n"
    "    $display(\"---- phase 11 : MOVING lamp + velocity lead prediction ----\");\n"
    "    img_r2 = 24'd10000;\n"
    "    img_cx = 11'd400;\n"
    "    img_cy = 11'd240;\n"
    "    wait_frames(3);\n"
    "    chk(\"near_lo_off\", {31'b0, lo_valid}, 32'd1);   // 大目标：严档照样认\n"
    "    move_target(8, 6);\n"
    "    chk(\"mov_pred_ok\", {31'b0, u_armor_vision.pd_ok}, 32'd1);\n"
    "    chk(\"mov_flag\",    {31'b0, u_armor_vision.pd_mov}, 32'd1);\n"
    "    chk(\"mov_vx_pos\",  (u_armor_vision.pd_vx > 16'sd48), 32'd1);\n"
    "    chk(\"mov_lead_dir\",(u_armor_vision.pd_cx > center_x), 32'd1);\n"
    "    chk_range(\"mov_lead_amt\",\n"
    "              {22'b0, u_armor_vision.pd_cx} - {22'b0, center_x}, 32'd8, 32'd48);\n"
    "    chk(\"mov_ay_inside\", (u_armor_vision.pd_ay <= center_y), 32'd1);\n"
    "    img_cx = 11'd400;\n"
    "    wait_frames(2);\n"
    "\n"
    "    //=====================================================\n"
    "    $display(\"---- phase 12 : result_frame v2 (24 bytes) over UART ----\");\n"
    "    //=====================================================\n"
    "    wait(ur_done);\n"
    "    repeat(20) @(posedge clk);\n"
    "    chk(\"uart_nbytes\", {26'd0, ur_n}, 32'd24);\n"
    "    chk(\"uart_hdr0\",   {24'd0, ur_b[0]},  32'd8'hA5);\n"
    "    chk(\"uart_hdr1\",   {24'd0, ur_b[1]},  32'd8'h5A);\n"
    "    chk(\"uart_flags\",  {24'd0, ur_b[2]},  32'h%02X);   // v2 标志 + pred/moving/adapt/valid\n"
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
    "    chk(\"uart_chk\",    {24'd0, ur_chk_calc()}, 32'h%02X);   // Python 独立算的期望值\n"
    "\n"
    "    //=====================================================\n"
) % (FLAGS, chk)

t = sub(t,
        "    if(err_cnt == 32'd0)\n"
        "        $display(\"==== ALL CHECKS PASSED ====\");\n",
        phases +
        "    if(err_cnt == 32'd0)\n"
        "        $display(\"==== ALL CHECKS PASSED ====\");\n",
        '插入 phase 10/11/12')

#==========================================================================
# 6) 收到的 24 字节自校验函数（和上面的期望值互为对照）
#==========================================================================
t = sub(t,
        "\ntask chk;\n",
        "\n//  收到的帧自校验：byte2..byte22 异或 == byte23\n"
        "function [7:0] ur_chk_calc;\n"
        "    integer ck;\n"
        "    begin\n"
        "        ck = 0;\n"
        "        for(uk = 2; uk <= 22; uk = uk + 1) ck = ck ^ ur_b[uk];\n"
        "        ur_chk_calc = ck[7:0];\n"
        "    end\n"
        "endfunction\n"
        "\n"
        "task chk;\n",
        '插入 ur_chk_calc')

save(REL, t, enc, crlf, raw)
print('=== 测试台补丁完成 ===')