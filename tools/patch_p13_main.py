# -*- coding: utf-8 -*-
"""
patch_p13_main.py -- P13 主体：a(合成靶标) + c(距离自适应提前量) + d(状态页)

1) rtl/aim_predict.v  加内建 1/w 提前量表 LEAD_MEM（(* rom_style="distributed" *) + initial，
   与 ballistic.v 同一套写法），提前量改成按距离自动算：
       t_flight = (14135/w)cm / 100 / 20m/s ; frames = t*30fps ; lead_q4 = 16*frames
       -> lead_q4 = 3392.4 / w   （w=28 -> 121 = 7.6帧/253ms；w=200 -> 17 = 1.06帧/35ms）
   表由 tools/gen_lead_lut.py 生成；0x11 = 0 或宽度超出 12~255px 时回退到手动 0x0A。
2) rtl/syn_target.v   新模块：板上合成靶标（匀速往返的绿圆）
3) rtl/armor_vision.v 接线：像素源二选一、lead_auto、状态页（数码管 + LED）
"""
import os

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)


def load(path):
    with open(os.path.join(ROOT, path), 'rb') as fh:
        raw = fh.read()
    t = raw.decode('gbk')
    return raw, t, ('\r\n' in t)


def save(path, raw, t, crlf):
    out = t.replace('\n', '\r\n') if crlf else t
    with open(os.path.join(ROOT, path), 'wb') as fh:
        fh.write(out.encode('gbk'))
    with open(os.path.join(ROOT, path), 'rb') as fh:
        if fh.read().decode('gbk') != out:
            raise SystemExit('**** %s 回读比对失败 ****' % path)
    print('[ok]   %s  %d -> %d bytes' % (path, len(raw), len(out.encode('gbk'))))


def sub(t, old, new, what):
    if t.count(old) != 1:
        raise SystemExit('%s：锚点匹配 %d 处（应为 1）' % (what, t.count(old)))
    print('[ok]   %s' % what)
    return t.replace(old, new)


# =====================================================================
# 1) aim_predict.v
# =====================================================================
rel = 'rtl/aim_predict.v'
raw, t, crlf = load(rel)
t = t.replace('\r\n', '\n')

t = sub(t, "    input      [7:0]         lead_q4   ,   // 提前量（帧 x16）\n",
        "    input      [7:0]         lead_q4   ,   // 手动提前量（帧 x16，0x0A）\n"
        "    input                    lead_auto ,   // P13: 1 = 按距离自动算（0x11）\n",
        'aim_predict: 加 lead_auto 端口')

t = sub(t, "    output reg               moving        // 目标在动（超过 MOVE_Q4）\n",
        "    output reg               moving    ,   // 目标在动（超过 MOVE_Q4）\n"
        "    output     [7:0]         lead_used     // 本次实际用的提前量（ILA/仿真观测）\n",
        'aim_predict: 加 lead_used 输出')

rom = ["//-------------------------------------------------------",
       "//  P13 提前量表：lead_q4 = 3392.4 / w（同样只是 1/w）",
       "//    t_flight = (14135/w)cm/100/20m/s ；frames = t x 30fps ；lead_q4 = 16 x frames",
       "//    w=28(5.05m)->121(7.6帧/253ms)   w=100(1.41m)->34   w=200(0.71m)->17(1.06帧/35ms)",
       "//    与 ballistic.v 的 dist/drop 两张表同源；改弹速基准就重跑 tools/gen_lead_lut.py",
       "//-------------------------------------------------------",
       "(* rom_style = \"distributed\" *) reg [7:0] LEAD_MEM [0:255];",
       "initial begin"]
for w in range(256):
    v = 0 if w == 0 else min(255, int(round(3392.4 / w)))
    rom.append("        LEAD_MEM[%3d] = 8'd%3d;" % (w, v))
rom += ["end",
        "",
        "wire [AW:0]  ld_idx    = (bw > {{AW{1'b0}}, 8'd255}) ? {{AW{1'b0}}, 8'd255} : bw;",
        "wire [7:0]   lead_rom  = LEAD_MEM[ld_idx[7:0]];",
        "//  只有宽度落在 12~255px（约 0.55m~11.8m）才认为距离可信，否则回退手动值",
        "wire         lead_ok   = lead_auto && (bw >= {{AW{1'b0}}, 4'd12}) && (bw <= {{AW{1'b0}}, 8'd255});",
        "assign       lead_used = lead_ok ? lead_rom : lead_q4;",
        ""]

t = sub(t, "// 外推：off = (v * LEAD_Q4) >>> 8   （Q4 x Q4 -> 整数像素）\n",
        "\n".join(rom) + "\n// 外推：off = (v * LEAD) >>> 8   （Q4 x Q4 -> 整数像素）\n",
        'aim_predict: 内建提前量表')

t = sub(t, "wire signed [31:0]   mulx = vxn * $signed({1'b0, lead_q4});\n"
           "wire signed [31:0]   muly = vyn * $signed({1'b0, lead_q4});\n",
        "wire signed [31:0]   mulx = vxn * $signed({1'b0, lead_used});\n"
        "wire signed [31:0]   muly = vyn * $signed({1'b0, lead_used});\n",
        'aim_predict: 外推改用 lead_used')
save(rel, raw, t, crlf)

# =====================================================================
# 2) syn_target.v（组合输出，逐像素与 data_v/x_v/y_cnt 对齐）
# =====================================================================
syn = """`timescale 1ns / 1ps
//****************************************************************************************//
// File name:           syn_target
// Descriptions:        板上合成靶标发生器（P13a）—— 不用相机/灯/上位机就能自检全链路
//
//   为什么要：
//     现场最麻烦的是「没有可复现的目标」：真人拿灯晃，速度不可控、每次都不一样，
//     预测/弹道这类依赖时序的功能根本没法验。这个模块自己造一个匀速往返的绿圆，
//     打开后顶替相机像素 -> 「分割 -> 团块 -> 预测 -> 弹道 -> 上报/显示」整条链路
//     都能在板子上跑，而且目标速度是精确已知的（可以直接和上报的 vx_q4 对表）。
//
//   怎么用：
//     UART 写 0x0F = 1 打开（写 0 回到相机）；0x0D 改速度（有符号 Q4 px/帧，
//     80 = 5.0 px/帧，负数反向）；0x0E 改半径（默认 60 -> 直径 120px，落在推荐取景范围）。
//
//   坐标约定（关键）：
//     x_v / y_cnt 与 data_v 是同一拍（都是 de 打一拍后的），所以 pix 用组合输出、
//     直接替 data_v 就是逐像素对齐的；圆画在 (400,240)，经 8 像素形态学偏移后
//     下游报出来正好是 (408,248)，与仿真期望一致。
//
//   资源：2 个平方 + 比较器，约 50 LUT / 60 FF / 2~4 DSP（组合输出，20ns 内够用）。
//         默认关闭时也照占（开关是运行时的）；想彻底省掉就把整个例化放进 generate。
//****************************************************************************************//
module syn_target #(
    parameter AW     = 10    ,   // 坐标位宽
    parameter WIDTH  = 800   ,   // 图像宽
    parameter HEIGHT = 480   ,   // 图像高
    parameter [15:0] PIX_GREEN = 16'h750E,   // 目标色（G-R=G-B=44，与相机/仿真一致）
    parameter [15:0] PIX_BG    = 16'h8410    // 背景（灰，绝不会被判成绿）
)(
    input                clk     ,
    input                rst_n   ,
    input                vsync   ,   // 帧起始脉冲：每帧动一次
    input      [AW-1:0]  x       ,   // 当前像素 x（x_v）
    input      [AW-1:0]  y       ,   // 当前行（y_cnt，1 基）
    input      [7:0]     spd_q4  ,   // 有符号 Q4 px/帧
    input      [AW-1:0]  rad     ,   // 半径（像素）
    output     [15:0]    pix     ,   // 合成像素（组合输出，与 x/y 同拍）
    output     [AW-1:0]  cx          // 当前圆心 x（调试/ILA）
);

//localparam
localparam [AW-1:0] X_MAX = WIDTH - 1;
localparam [AW-1:0] Y_MID = HEIGHT / 2;

//reg define
reg  signed [23:0] cx_q4 ;       // 圆心 x（Q4）
reg  signed [23:0] vx_q4 ;       // 当前速度（Q4，碰边取反 -> 往返）
reg        [23:0]  r2    ;       // 半径平方（每帧算一次）

//wire define
wire signed [23:0] spd_s  = $signed({{16{spd_q4[7]}}, spd_q4});
wire signed [23:0] lo_lim = $signed({14'd0, rad}) <<< 4;
wire signed [23:0] hi_lim = $signed({14'd0, (X_MAX - rad)}) <<< 4;
wire signed [23:0] nx     = cx_q4 + vx_q4;
wire               bounce = (nx > hi_lim) || (nx < lo_lim);
wire signed [23:0] nx_cl  = (nx > hi_lim) ? hi_lim : ((nx < lo_lim) ? lo_lim : nx);
wire signed [23:0] cx_now = cx_q4 >>> 4;

//  逐像素：|x-cx|^2 + |y-cy|^2 与 r^2 比较（都取绝对值，回避有符号平方的坑）
wire signed [AW:0] dxs = $signed({1'b0, x}) - $signed({1'b0, cx_now[AW-1:0]});
wire signed [AW:0] dys = $signed({1'b0, y}) - $signed({1'b0, Y_MID});
wire        [AW:0] dxa = dxs[AW] ? (~dxs + 1'b1) : dxs;
wire        [AW:0] dya = dys[AW] ? (~dys + 1'b1) : dys;
wire [2*AW+1:0]    dist2 = dxa*dxa + dya*dya;

assign cx  = cx_now[AW-1:0];
assign pix = (dist2 <= {{(2*AW+2-24){1'b0}}, r2}) ? PIX_GREEN : PIX_BG;

//-------------------------------------------------------
// 每帧动一次（vsync 脉冲）；碰到边缘就把速度取反
//-------------------------------------------------------
always @(posedge clk or negedge rst_n) begin
    if(!rst_n) begin
        cx_q4 <= $signed({14'd0, (WIDTH/2)}) <<< 4;
        vx_q4 <= 24'sd80;                 // 默认 5.0 px/帧
    end
    else if(vsync) begin
        cx_q4 <= nx_cl;
        vx_q4 <= bounce ? -spd_s : spd_s;
    end
end

//-------------------------------------------------------
// 半径平方：每帧更新一次（默认 60 -> 3600）
//-------------------------------------------------------
always @(posedge clk or negedge rst_n) begin
    if(!rst_n) r2 <= 24'd0;
    else if(vsync) r2 <= {14'd0, rad} * {14'd0, rad};
end

endmodule
"""
with open(os.path.join(ROOT, 'rtl/syn_target.v'), 'wb') as fh:
    fh.write(syn.replace('\n', '\r\n').encode('gbk'))
with open(os.path.join(ROOT, 'rtl/syn_target.v'), 'rb') as fh:
    if fh.read().decode('gbk') != syn.replace('\n', '\r\n'):
        raise SystemExit('**** syn_target.v 回读比对失败 ****')
print('[ok]   rtl/syn_target.v 新建（%d bytes）' % len(syn.replace('\n', '\r\n').encode('gbk')))

# =====================================================================
# 3) armor_vision.v
# =====================================================================
rel = 'rtl/armor_vision.v'
raw, t, crlf = load(rel)
t = t.replace('\r\n', '\n')

t = sub(t, "wire          mask_t, de_t   ;   // 累积后的掩码（与 x_t/y_t 对齐）\n",
        "wire          mask_t, de_t   ;   // 累积后的掩码（与 x_t/y_t 对齐）\n"
        "\n"
        "//  ---- P13 ----\n"
        "wire [7:0]    rf_syn_spd, rf_syn_r, rf_syn_en, rf_st_page, rf_lead_auto;\n"
        "wire          syn_on   ;\n"
        "wire [15:0]   syn_pix  ;\n"
        "wire [15:0]   cam_pix  ;   // 真正进管线的像素（相机 or 合成）\n"
        "wire [AW-1:0] syn_cx   ;\n"
        "wire [1:0]    st_page  ;\n"
        "wire [7:0]    pd_lead  ;   // 实际使用的提前量（ILA/仿真观测）\n",
        'armor_vision: P13 新 wire')

t = sub(t, "    .r_tacc     (rf_tacc    ),\n",
        "    .r_tacc     (rf_tacc    ),\n"
        "    .r_syn_spd  (rf_syn_spd ),\n"
        "    .r_syn_r    (rf_syn_r   ),\n"
        "    .r_syn_en   (rf_syn_en  ),\n"
        "    .r_st_page  (rf_st_page ),\n"
        "    .r_lead_auto(rf_lead_auto),\n",
        'armor_vision: reg_file 新端口')

t = sub(t, "//-------------------------------------------------------\n"
           "// (3) 中值预滤波（MED）：关时直通、零延迟）\n",
        "//-------------------------------------------------------\n"
        "// (2c) P13a 合成靶标：UART 0x0F=1 时顶替相机像素（默认关闭，行为与原来完全一致）\n"
        "//-------------------------------------------------------\n"
        "assign syn_on = rf_syn_en[0];\n"
        "\n"
        "syn_target #(\n"
        "    .AW     (AW    ),\n"
        "    .WIDTH  (IMG_W ),\n"
        "    .HEIGHT (IMG_H )\n"
        ") u_syn_target (\n"
        "    .clk    (clk        ),\n"
        "    .rst_n  (rst_n      ),\n"
        "    .vsync  (vsync      ),\n"
        "    .x      (x_v        ),\n"
        "    .y      (y_cnt      ),\n"
        "    .spd_q4 (rf_syn_spd ),\n"
        "    .rad    (rf_syn_r   ),\n"
        "    .pix    (syn_pix    ),\n"
        "    .cx     (syn_cx     )\n"
        ");\n"
        "\n"
        "assign cam_pix = syn_on ? syn_pix : data_v;\n"
        "\n"
        "//-------------------------------------------------------\n"
        "// (3) 中值预滤波（MED）：关时直通、零延迟）\n",
        'armor_vision: 合成靶标实例 + 像素源')

t = sub(t, "    .din   (data_v ),\n    .de_o  (med_de ),", "    .din   (cam_pix),\n    .de_o  (med_de ),",
        'armor_vision: median 用 cam_pix')
t = sub(t, "assign pix_seg = med_on ? med_pix : data_v;", "assign pix_seg = med_on ? med_pix : cam_pix;",
        'armor_vision: pix_seg 用 cam_pix')
t = sub(t, "    .din   (data_v ),\n    .dout  (img_d  )", "    .din   (cam_pix),\n    .dout  (img_d  )",
        'armor_vision: video_delay 用 cam_pix')

t = sub(t, "    .lead_q4   (lead_q4_eff),\n",
        "    .lead_q4   (lead_q4_eff),\n    .lead_auto (rf_lead_auto[0]),\n",
        'armor_vision: aim_predict 接 lead_auto')
t = sub(t, "    .moving    (pd_mov    )\n);\n",
        "    .moving    (pd_mov    ),\n    .lead_used (pd_lead   )\n);\n",
        'armor_vision: aim_predict 接 lead_used')

t = sub(t, "assign tacc_clr    = reg_written & rf_tacc[7];",
        "assign tacc_clr    = reg_written & rf_tacc[7];\n"
        "\n"
        "//  P13d 状态页：0 = 正常  1 = 距离(cm) / 下坠  2 = 宽度(px) / 距离  3 = 速度(px/帧)\n"
        "assign st_page = rf_st_page[1:0];\n"
        "\n"
        "wire [7:0] st_v3 = (st_page == 2'd1) ? bl_dist_cm[7:0] :\n"
        "                   (st_page == 2'd2) ? bond_w[7:0] :\n"
        "                   (st_page == 2'd3) ? ((pd_vx[15]) ? 8'd0 : {1'b0, pd_vx[14:7]}) : th_g;\n"
        "wire [7:0] st_w2 = (st_page == 2'd1) ? bl_drop_px[7:0] :\n"
        "                   (st_page == 2'd2) ? bl_dist_cm[7:0] :\n"
        "                   (st_page == 2'd3) ? bond_w[7:0] : 8'd0;\n",
        'armor_vision: 状态页选择')

t = sub(t, "    .th_g       (th_g   ),\n"
           "    .th_gr      (th_gr  ),\n"
           "    .th_gb      (th_gb  ),\n"
           "    .bond_valid (bond_valid ),\n"
           "    .bond_w     (bond_w     ),\n",
        "    .th_g       ((st_page == 2'd0) ? th_g : st_v3),\n"
        "    .th_gr      ((st_page == 2'd0) ? th_gr : st_v3),\n"
        "    .th_gb      ((st_page == 2'd0) ? th_gb : st_v3),\n"
        "    .bond_valid (bond_valid ),\n"
        "    .bond_w     ((st_page == 2'd0) ? bond_w : {st_w2, 2'b00}),\n",
        'armor_vision: seg_display 状态页 mux')

t = sub(t, "assign led[0] = ~(sel == 2'd0);\n"
           "assign led[1] = ~(sel == 2'd1);\n"
           "assign led[2] = ~(sel == 2'd2);\n",
        "//  状态页时 LED 改成状态位（不用接串口）：led[0]=预测有效 led[1]=目标在动 led[2]=距离有效\n"
        "assign led[0] = ~((st_page != 2'd0) ? pd_ok  : (sel == 2'd0));\n"
        "assign led[1] = ~((st_page != 2'd0) ? pd_mov : (sel == 2'd1));\n"
        "assign led[2] = ~((st_page != 2'd0) ? bl_ok  : (sel == 2'd2));\n",
        'armor_vision: LED 状态页')

save(rel, raw, t, crlf)
print('=== P13 a/c/d 主体完成 ===')
