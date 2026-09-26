`timescale 1ns / 1ps
//****************************************************************************************//
// File name:           aim_predict
// Descriptions:        速度预测（lead 提前量）—— 预测飞镖到底该指向哪里
//
//   为什么需要：
//     舵机跟踪只要「绿灯现在在哪」；但要打中，需要「飞镖飞到的时候灯在哪」。
//     飞镖飞行时间约 0.1~0.3s（随距离变），这段时间目标会移动，
//     直接瞄当前灯心必然滞后，等于永远差一个「飞行时间 x 目标速度」。
//     本模块用最近几帧的灯心做速度估计（Q4 定点，单位 px/帧），外推 LEAD 帧，
//     输出【预测灯心】和【预测瞄准点】，直接给云台 / 飞控用。
//
//   时序（和 blob_track / track_ab 同一套写法）：
//     frame_end = vsync 下降沿延一拍。
//     为什么要延一拍：blob_track 在 vsync_fall 那一拍更新输出，如果本模块也在同一拍
//     取用，nonblocking 语义下拿到的是【上一帧】的值（多滞后一帧）。延一拍后
//     读到的是「刚刚结束那一帧」的 raw_*，正好是最新观测。
//     （这个「同一拍改激励 / 取结果」的坑在 track_ab 那里踩过一次，见 doc 第 16 节。）
//
//   速度估计（Q4：1 px/帧 记为 16）：
//       d4 = (cx - cx_prev) << 4
//       v  <= v + ((d4 - v) >>> VSHIFT)          // VSHIFT=2 -> alpha=0.25，抗单帧抖动
//   预测（LEAD_Q4 同 Q4：64 = 4.0 帧，30fps 下约 133ms）：
//       off = (v * LEAD_Q4) >>> 8
//       pcx = clamp(cx + off)                    // 饱和到画面内，不回绕
//       pay = pcy - up,   up = bw * aim_h_q8 / 256    // 与 blob_track 同一公式 + 饱和
//
//   历史不足（连续有效帧 < 2）或 raw_valid=0 时：pred_ok = 0，
//   输出【直接镜像当前帧】，等于不预测。
//   => 静止目标下本模块开 / 关的输出完全一样，不会改变已经验收过的行为。
//
//   资源：2 个乘法器（v x LEAD、bw x aim_h），约 200 LUT / 150 FF，0 BRAM / 2 DSP。
//****************************************************************************************//
module aim_predict #(
    parameter AW            = 10    ,   // 坐标位宽
    parameter WIDTH         = 800   ,   // 图像宽
    parameter HEIGHT        = 480   ,   // 图像高
    parameter [7:0] VSHIFT  = 8'd2  ,   // 速度平滑：(新 - 旧) >>> VSHIFT
    //  P14：门限从 1px/帧 提到 2px/帧 —— 斜置屏幕下 cx/cy 有 ±1px 抖动，
    //  1px 门限会被抖出「在动」，黄十字乱闪；2px 只承认真的在动。
    parameter [7:0] MOVE_Q4 = 8'd32     // |vx|+|vy| >= 它才算「在动」（32 = 2 px/帧）
)(
    input                    clk       ,
    input                    rst_n     ,
    input                    vsync     ,
    input                    en        ,   // PRED_EN（总开关）
    input                    raw_valid ,   // blob_track 本帧是否找到团块
    input      [AW-1:0]      cx        ,   // 本帧灯心 x
    input      [AW-1:0]      cy        ,   // 本帧灯心 y
    input      [AW:0]        bw        ,   // 本帧灯宽（算几何偏移用）
    input      [15:0]        aim_h_q8  ,   // 几何偏移 = 宽度 x aim_h_q8/256
    input      [7:0]         lead_q4   ,   // 手动提前量（帧 x16，0x0A）
    input                    lead_auto ,   // P13: 1 = 按距离自动算（0x11）

    output reg [AW-1:0]      pcx       ,   // 预测灯心 x
    output reg [AW-1:0]      pcy       ,   // 预测灯心 y
    output reg [AW-1:0]      pay       ,   // 预测瞄准点 y（= pcy - 几何偏移，饱和）
    output reg signed [15:0] vx_q4     ,   // 速度估计 Q4（px/帧 x16，带符号）
    output reg signed [15:0] vy_q4     ,
    output reg               pred_ok   ,   // 预测有效（连续有效帧 >= 2）
    output reg               moving    ,   // 目标在动（超过 MOVE_Q4）
    output     [7:0]         lead_used     // 本次实际用的提前量（ILA/仿真观测）
);

//localparam
localparam VW = AW + 6;                     // 速度 / 位置的内部位宽（AW=10 -> 16bit）
localparam signed [VW-1:0] W_MAXV = WIDTH  - 1;
localparam signed [VW-1:0] H_MAXV = HEIGHT - 1;

//reg define
reg                  vsync_d  ;
reg                  frame_end;
reg  [AW-1:0]        cx_p     ;   // 上一帧灯心
reg  [AW-1:0]        cy_p     ;
reg  [1:0]           hist     ;   // 连续有效帧数（饱和到 3）
reg  signed [VW-1:0] vx_s     ;   // 速度状态（Q4）
reg  signed [VW-1:0] vy_s     ;

//wire define
wire vsync_fall = ~vsync & vsync_d;

//-------------------------------------------------------
// 帧边界：延一拍，读到的是刚刚结束那一帧的结果
//-------------------------------------------------------
always @(posedge clk or negedge rst_n) begin
    if(!rst_n) begin
        vsync_d   <= 1'b0;
        frame_end <= 1'b0;
    end
    else begin
        vsync_d   <= vsync;
        frame_end <= vsync_fall;
    end
end

//-------------------------------------------------------
// 速度估计（组合）
//   只有「连续有效」才更新；丢帧时清零，不拿丢弃帧的残值去估速度
//-------------------------------------------------------
wire signed [VW-1:0] dx4 = ($signed({1'b0, cx}) - $signed({1'b0, cx_p})) <<< 4;
wire signed [VW-1:0] dy4 = ($signed({1'b0, cy}) - $signed({1'b0, cy_p})) <<< 4;
wire signed [VW-1:0] nvx = vx_s + ((dx4 - vx_s) >>> VSHIFT);
wire signed [VW-1:0] nvy = vy_s + ((dy4 - vy_s) >>> VSHIFT);

wire use_pred = en && raw_valid && (hist >= 2'd2);

wire signed [VW-1:0] vxn = use_pred ? nvx : {VW{1'b0}};
wire signed [VW-1:0] vyn = use_pred ? nvy : {VW{1'b0}};

//-------------------------------------------------------
//-------------------------------------------------------
//  P13 提前量表：lead_q4 = 3392.4 / w（同样只是 1/w）
//    t_flight = (14135/w)cm/100/20m/s ；frames = t x 30fps ；lead_q4 = 16 x frames
//    w=28(5.05m)->121(7.6帧/253ms)   w=100(1.41m)->34   w=200(0.71m)->17(1.06帧/35ms)
//    与 ballistic.v 的 dist/drop 两张表同源；改弹速基准就重跑 tools/gen_lead_lut.py
//-------------------------------------------------------
(* rom_style = "distributed" *) reg [7:0] LEAD_MEM [0:255];
initial begin
        LEAD_MEM[  0] = 8'd  0;
        LEAD_MEM[  1] = 8'd255;
        LEAD_MEM[  2] = 8'd255;
        LEAD_MEM[  3] = 8'd255;
        LEAD_MEM[  4] = 8'd255;
        LEAD_MEM[  5] = 8'd255;
        LEAD_MEM[  6] = 8'd255;
        LEAD_MEM[  7] = 8'd255;
        LEAD_MEM[  8] = 8'd255;
        LEAD_MEM[  9] = 8'd255;
        LEAD_MEM[ 10] = 8'd255;
        LEAD_MEM[ 11] = 8'd255;
        LEAD_MEM[ 12] = 8'd255;
        LEAD_MEM[ 13] = 8'd255;
        LEAD_MEM[ 14] = 8'd242;
        LEAD_MEM[ 15] = 8'd226;
        LEAD_MEM[ 16] = 8'd212;
        LEAD_MEM[ 17] = 8'd200;
        LEAD_MEM[ 18] = 8'd188;
        LEAD_MEM[ 19] = 8'd179;
        LEAD_MEM[ 20] = 8'd170;
        LEAD_MEM[ 21] = 8'd162;
        LEAD_MEM[ 22] = 8'd154;
        LEAD_MEM[ 23] = 8'd147;
        LEAD_MEM[ 24] = 8'd141;
        LEAD_MEM[ 25] = 8'd136;
        LEAD_MEM[ 26] = 8'd130;
        LEAD_MEM[ 27] = 8'd126;
        LEAD_MEM[ 28] = 8'd121;
        LEAD_MEM[ 29] = 8'd117;
        LEAD_MEM[ 30] = 8'd113;
        LEAD_MEM[ 31] = 8'd109;
        LEAD_MEM[ 32] = 8'd106;
        LEAD_MEM[ 33] = 8'd103;
        LEAD_MEM[ 34] = 8'd100;
        LEAD_MEM[ 35] = 8'd 97;
        LEAD_MEM[ 36] = 8'd 94;
        LEAD_MEM[ 37] = 8'd 92;
        LEAD_MEM[ 38] = 8'd 89;
        LEAD_MEM[ 39] = 8'd 87;
        LEAD_MEM[ 40] = 8'd 85;
        LEAD_MEM[ 41] = 8'd 83;
        LEAD_MEM[ 42] = 8'd 81;
        LEAD_MEM[ 43] = 8'd 79;
        LEAD_MEM[ 44] = 8'd 77;
        LEAD_MEM[ 45] = 8'd 75;
        LEAD_MEM[ 46] = 8'd 74;
        LEAD_MEM[ 47] = 8'd 72;
        LEAD_MEM[ 48] = 8'd 71;
        LEAD_MEM[ 49] = 8'd 69;
        LEAD_MEM[ 50] = 8'd 68;
        LEAD_MEM[ 51] = 8'd 67;
        LEAD_MEM[ 52] = 8'd 65;
        LEAD_MEM[ 53] = 8'd 64;
        LEAD_MEM[ 54] = 8'd 63;
        LEAD_MEM[ 55] = 8'd 62;
        LEAD_MEM[ 56] = 8'd 61;
        LEAD_MEM[ 57] = 8'd 60;
        LEAD_MEM[ 58] = 8'd 58;
        LEAD_MEM[ 59] = 8'd 57;
        LEAD_MEM[ 60] = 8'd 57;
        LEAD_MEM[ 61] = 8'd 56;
        LEAD_MEM[ 62] = 8'd 55;
        LEAD_MEM[ 63] = 8'd 54;
        LEAD_MEM[ 64] = 8'd 53;
        LEAD_MEM[ 65] = 8'd 52;
        LEAD_MEM[ 66] = 8'd 51;
        LEAD_MEM[ 67] = 8'd 51;
        LEAD_MEM[ 68] = 8'd 50;
        LEAD_MEM[ 69] = 8'd 49;
        LEAD_MEM[ 70] = 8'd 48;
        LEAD_MEM[ 71] = 8'd 48;
        LEAD_MEM[ 72] = 8'd 47;
        LEAD_MEM[ 73] = 8'd 46;
        LEAD_MEM[ 74] = 8'd 46;
        LEAD_MEM[ 75] = 8'd 45;
        LEAD_MEM[ 76] = 8'd 45;
        LEAD_MEM[ 77] = 8'd 44;
        LEAD_MEM[ 78] = 8'd 43;
        LEAD_MEM[ 79] = 8'd 43;
        LEAD_MEM[ 80] = 8'd 42;
        LEAD_MEM[ 81] = 8'd 42;
        LEAD_MEM[ 82] = 8'd 41;
        LEAD_MEM[ 83] = 8'd 41;
        LEAD_MEM[ 84] = 8'd 40;
        LEAD_MEM[ 85] = 8'd 40;
        LEAD_MEM[ 86] = 8'd 39;
        LEAD_MEM[ 87] = 8'd 39;
        LEAD_MEM[ 88] = 8'd 39;
        LEAD_MEM[ 89] = 8'd 38;
        LEAD_MEM[ 90] = 8'd 38;
        LEAD_MEM[ 91] = 8'd 37;
        LEAD_MEM[ 92] = 8'd 37;
        LEAD_MEM[ 93] = 8'd 36;
        LEAD_MEM[ 94] = 8'd 36;
        LEAD_MEM[ 95] = 8'd 36;
        LEAD_MEM[ 96] = 8'd 35;
        LEAD_MEM[ 97] = 8'd 35;
        LEAD_MEM[ 98] = 8'd 35;
        LEAD_MEM[ 99] = 8'd 34;
        LEAD_MEM[100] = 8'd 34;
        LEAD_MEM[101] = 8'd 34;
        LEAD_MEM[102] = 8'd 33;
        LEAD_MEM[103] = 8'd 33;
        LEAD_MEM[104] = 8'd 33;
        LEAD_MEM[105] = 8'd 32;
        LEAD_MEM[106] = 8'd 32;
        LEAD_MEM[107] = 8'd 32;
        LEAD_MEM[108] = 8'd 31;
        LEAD_MEM[109] = 8'd 31;
        LEAD_MEM[110] = 8'd 31;
        LEAD_MEM[111] = 8'd 31;
        LEAD_MEM[112] = 8'd 30;
        LEAD_MEM[113] = 8'd 30;
        LEAD_MEM[114] = 8'd 30;
        LEAD_MEM[115] = 8'd 29;
        LEAD_MEM[116] = 8'd 29;
        LEAD_MEM[117] = 8'd 29;
        LEAD_MEM[118] = 8'd 29;
        LEAD_MEM[119] = 8'd 29;
        LEAD_MEM[120] = 8'd 28;
        LEAD_MEM[121] = 8'd 28;
        LEAD_MEM[122] = 8'd 28;
        LEAD_MEM[123] = 8'd 28;
        LEAD_MEM[124] = 8'd 27;
        LEAD_MEM[125] = 8'd 27;
        LEAD_MEM[126] = 8'd 27;
        LEAD_MEM[127] = 8'd 27;
        LEAD_MEM[128] = 8'd 27;
        LEAD_MEM[129] = 8'd 26;
        LEAD_MEM[130] = 8'd 26;
        LEAD_MEM[131] = 8'd 26;
        LEAD_MEM[132] = 8'd 26;
        LEAD_MEM[133] = 8'd 26;
        LEAD_MEM[134] = 8'd 25;
        LEAD_MEM[135] = 8'd 25;
        LEAD_MEM[136] = 8'd 25;
        LEAD_MEM[137] = 8'd 25;
        LEAD_MEM[138] = 8'd 25;
        LEAD_MEM[139] = 8'd 24;
        LEAD_MEM[140] = 8'd 24;
        LEAD_MEM[141] = 8'd 24;
        LEAD_MEM[142] = 8'd 24;
        LEAD_MEM[143] = 8'd 24;
        LEAD_MEM[144] = 8'd 24;
        LEAD_MEM[145] = 8'd 23;
        LEAD_MEM[146] = 8'd 23;
        LEAD_MEM[147] = 8'd 23;
        LEAD_MEM[148] = 8'd 23;
        LEAD_MEM[149] = 8'd 23;
        LEAD_MEM[150] = 8'd 23;
        LEAD_MEM[151] = 8'd 22;
        LEAD_MEM[152] = 8'd 22;
        LEAD_MEM[153] = 8'd 22;
        LEAD_MEM[154] = 8'd 22;
        LEAD_MEM[155] = 8'd 22;
        LEAD_MEM[156] = 8'd 22;
        LEAD_MEM[157] = 8'd 22;
        LEAD_MEM[158] = 8'd 21;
        LEAD_MEM[159] = 8'd 21;
        LEAD_MEM[160] = 8'd 21;
        LEAD_MEM[161] = 8'd 21;
        LEAD_MEM[162] = 8'd 21;
        LEAD_MEM[163] = 8'd 21;
        LEAD_MEM[164] = 8'd 21;
        LEAD_MEM[165] = 8'd 21;
        LEAD_MEM[166] = 8'd 20;
        LEAD_MEM[167] = 8'd 20;
        LEAD_MEM[168] = 8'd 20;
        LEAD_MEM[169] = 8'd 20;
        LEAD_MEM[170] = 8'd 20;
        LEAD_MEM[171] = 8'd 20;
        LEAD_MEM[172] = 8'd 20;
        LEAD_MEM[173] = 8'd 20;
        LEAD_MEM[174] = 8'd 19;
        LEAD_MEM[175] = 8'd 19;
        LEAD_MEM[176] = 8'd 19;
        LEAD_MEM[177] = 8'd 19;
        LEAD_MEM[178] = 8'd 19;
        LEAD_MEM[179] = 8'd 19;
        LEAD_MEM[180] = 8'd 19;
        LEAD_MEM[181] = 8'd 19;
        LEAD_MEM[182] = 8'd 19;
        LEAD_MEM[183] = 8'd 19;
        LEAD_MEM[184] = 8'd 18;
        LEAD_MEM[185] = 8'd 18;
        LEAD_MEM[186] = 8'd 18;
        LEAD_MEM[187] = 8'd 18;
        LEAD_MEM[188] = 8'd 18;
        LEAD_MEM[189] = 8'd 18;
        LEAD_MEM[190] = 8'd 18;
        LEAD_MEM[191] = 8'd 18;
        LEAD_MEM[192] = 8'd 18;
        LEAD_MEM[193] = 8'd 18;
        LEAD_MEM[194] = 8'd 17;
        LEAD_MEM[195] = 8'd 17;
        LEAD_MEM[196] = 8'd 17;
        LEAD_MEM[197] = 8'd 17;
        LEAD_MEM[198] = 8'd 17;
        LEAD_MEM[199] = 8'd 17;
        LEAD_MEM[200] = 8'd 17;
        LEAD_MEM[201] = 8'd 17;
        LEAD_MEM[202] = 8'd 17;
        LEAD_MEM[203] = 8'd 17;
        LEAD_MEM[204] = 8'd 17;
        LEAD_MEM[205] = 8'd 17;
        LEAD_MEM[206] = 8'd 16;
        LEAD_MEM[207] = 8'd 16;
        LEAD_MEM[208] = 8'd 16;
        LEAD_MEM[209] = 8'd 16;
        LEAD_MEM[210] = 8'd 16;
        LEAD_MEM[211] = 8'd 16;
        LEAD_MEM[212] = 8'd 16;
        LEAD_MEM[213] = 8'd 16;
        LEAD_MEM[214] = 8'd 16;
        LEAD_MEM[215] = 8'd 16;
        LEAD_MEM[216] = 8'd 16;
        LEAD_MEM[217] = 8'd 16;
        LEAD_MEM[218] = 8'd 16;
        LEAD_MEM[219] = 8'd 15;
        LEAD_MEM[220] = 8'd 15;
        LEAD_MEM[221] = 8'd 15;
        LEAD_MEM[222] = 8'd 15;
        LEAD_MEM[223] = 8'd 15;
        LEAD_MEM[224] = 8'd 15;
        LEAD_MEM[225] = 8'd 15;
        LEAD_MEM[226] = 8'd 15;
        LEAD_MEM[227] = 8'd 15;
        LEAD_MEM[228] = 8'd 15;
        LEAD_MEM[229] = 8'd 15;
        LEAD_MEM[230] = 8'd 15;
        LEAD_MEM[231] = 8'd 15;
        LEAD_MEM[232] = 8'd 15;
        LEAD_MEM[233] = 8'd 15;
        LEAD_MEM[234] = 8'd 14;
        LEAD_MEM[235] = 8'd 14;
        LEAD_MEM[236] = 8'd 14;
        LEAD_MEM[237] = 8'd 14;
        LEAD_MEM[238] = 8'd 14;
        LEAD_MEM[239] = 8'd 14;
        LEAD_MEM[240] = 8'd 14;
        LEAD_MEM[241] = 8'd 14;
        LEAD_MEM[242] = 8'd 14;
        LEAD_MEM[243] = 8'd 14;
        LEAD_MEM[244] = 8'd 14;
        LEAD_MEM[245] = 8'd 14;
        LEAD_MEM[246] = 8'd 14;
        LEAD_MEM[247] = 8'd 14;
        LEAD_MEM[248] = 8'd 14;
        LEAD_MEM[249] = 8'd 14;
        LEAD_MEM[250] = 8'd 14;
        LEAD_MEM[251] = 8'd 14;
        LEAD_MEM[252] = 8'd 13;
        LEAD_MEM[253] = 8'd 13;
        LEAD_MEM[254] = 8'd 13;
        LEAD_MEM[255] = 8'd 13;
end

wire [AW:0]  ld_idx    = (bw > {{AW{1'b0}}, 8'd255}) ? {{AW{1'b0}}, 8'd255} : bw;
wire [7:0]   lead_rom  = LEAD_MEM[ld_idx[7:0]];
//  只有宽度落在 12~255px（约 0.55m~11.8m）才认为距离可信，否则回退手动值
wire         lead_ok   = lead_auto && (bw >= {{AW{1'b0}}, 4'd12}) && (bw <= {{AW{1'b0}}, 8'd255});
assign       lead_used = lead_ok ? lead_rom : lead_q4;

// 外推：off = (v * LEAD) >>> 8   （Q4 x Q4 -> 整数像素）
//   饱和由 clamp 负责；|off| <= 32767*255/256 < 32767，不会溢出 16bit
//-------------------------------------------------------
wire signed [31:0]   mulx = vxn * $signed({1'b0, lead_used});
wire signed [31:0]   muly = vyn * $signed({1'b0, lead_used});
wire signed [VW-1:0] offx = mulx >>> 8;
wire signed [VW-1:0] offy = muly >>> 8;

//  饱和到画面内（不回绕）
function [AW-1:0] clampw;
    input signed [VW-1:0] v;
    begin
        if(v < 0)           clampw = {AW{1'b0}};
        else if(v > W_MAXV) clampw = W_MAXV[AW-1:0];
        else                clampw = v[AW-1:0];
    end
endfunction

function [AW-1:0] clamph;
    input signed [VW-1:0] v;
    begin
        if(v < 0)           clamph = {AW{1'b0}};
        else if(v > H_MAXV) clamph = H_MAXV[AW-1:0];
        else                clamph = v[AW-1:0];
    end
endfunction

wire [AW-1:0] pcx_c = clampw($signed({1'b0, cx}) + offx);
wire [AW-1:0] pcy_c = clamph($signed({1'b0, cy}) + offy);

//-------------------------------------------------------
// 几何偏移（和 blob_track 完全同一公式，保证静止时逐位一致）
//-------------------------------------------------------
wire [2*AW+8:0] up_full = bw * aim_h_q8;
wire [AW+8:0]   up_t    = up_full >> 8;
wire [AW+8:0]   pcy_l   = {9'd0, pcy_c};
wire [AW+8:0]   cy_l    = {9'd0, cy};
wire [AW+8:0]   pay_p   = (pcy_l >= up_t) ? (pcy_l - up_t) : {(AW+9){1'b0}};
wire [AW+8:0]   pay_r   = (cy_l  >= up_t) ? (cy_l  - up_t) : {(AW+9){1'b0}};

//-------------------------------------------------------
// 「在动」判定：|vx| + |vy| >= MOVE_Q4
//-------------------------------------------------------
function [VW-1:0] vabs;
    input signed [VW-1:0] v;
    begin
        vabs = v[VW-1] ? ((~v) + 1'b1) : v;
    end
endfunction

wire [VW:0] aspd     = {1'b0, vabs(vxn)} + {1'b0, vabs(vyn)};
wire        moving_c = use_pred && (aspd >= MOVE_Q4);

//-------------------------------------------------------
// 帧末更新
//-------------------------------------------------------
always @(posedge clk or negedge rst_n) begin
    if(!rst_n) begin
        cx_p <= {AW{1'b0}};
        cy_p <= {AW{1'b0}};
        hist <= 2'd0;
        vx_s <= {VW{1'b0}};
        vy_s <= {VW{1'b0}};
        pcx  <= {AW{1'b0}};
        pcy  <= {AW{1'b0}};
        pay  <= {AW{1'b0}};
        vx_q4 <= 16'sd0;
        vy_q4 <= 16'sd0;
        pred_ok <= 1'b0;
        moving  <= 1'b0;
    end
    else if(frame_end) begin
        cx_p <= cx;
        cy_p <= cy;
        vx_s <= vxn;
        vy_s <= vyn;
        hist <= raw_valid ? ((hist == 2'd3) ? 2'd3 : (hist + 2'd1)) : 2'd0;

        if(use_pred) begin
            pcx <= pcx_c;
            pcy <= pcy_c;
            pay <= pay_p[AW-1:0];
        end
        else begin
            pcx <= cx;                  // 历史不足 / 关闭 / 本帧无效 -> 镜像当前帧
            pcy <= cy;
            pay <= pay_r[AW-1:0];
        end

        pred_ok <= use_pred;
        moving  <= moving_c;
        vx_q4   <= vxn;
        vy_q4   <= vyn;
    end
end

endmodule
