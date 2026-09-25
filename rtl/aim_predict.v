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
    parameter [7:0] MOVE_Q4 = 8'd16     // |vx|+|vy| >= 它才算「在动」（16 = 1 px/帧）
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
    input      [7:0]         lead_q4   ,   // 提前量（帧 x16）

    output reg [AW-1:0]      pcx       ,   // 预测灯心 x
    output reg [AW-1:0]      pcy       ,   // 预测灯心 y
    output reg [AW-1:0]      pay       ,   // 预测瞄准点 y（= pcy - 几何偏移，饱和）
    output reg signed [15:0] vx_q4     ,   // 速度估计 Q4（px/帧 x16，带符号）
    output reg signed [15:0] vy_q4     ,
    output reg               pred_ok   ,   // 预测有效（连续有效帧 >= 2）
    output reg               moving        // 目标在动（超过 MOVE_Q4）
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
// 外推：off = (v * LEAD_Q4) >>> 8   （Q4 x Q4 -> 整数像素）
//   饱和由 clamp 负责；|off| <= 32767*255/256 < 32767，不会溢出 16bit
//-------------------------------------------------------
wire signed [31:0]   mulx = vxn * $signed({1'b0, lead_q4});
wire signed [31:0]   muly = vyn * $signed({1'b0, lead_q4});
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
