//****************************************Copyright (c)***********************************//
// File name:           overlay_box
// Descriptions:        在像素流上叠印【红色圆环 + 中心十字】（纯组合逻辑）
//
//   靶标是一个绿色圆，所以标记画成：
//     - 圆环：半径 R = (宽 + 高) / 4，环宽 ±RING_T 像素
//     - 十字：中心处一横一竖，臂长 CROSS_L、线宽 ±CROSS_T
//
//   圆环判据不用开根号（省 DSP / 时序）：
//        dx = x - cx ,  dy = y - cy
//        d2 = dx*dx + dy*dy
//        环上 <=> R_in^2 <= d2 <= R_out^2
//   两个平方用组合乘法，Vivado 会推断成 DSP48（7A35T 有 90 个，用几个没压力）。
//
//   与二值图/原图共用同一套像素流坐标，所以环一定贴着看到的绿圆：
//   video_delay 已经把原图延后 8 行 + 8 像素，和形态学输出对齐。
//----------------------------------------------------------------------------------------
//****************************************************************************************//

`timescale 1ns / 1ps

module overlay_box #(
    parameter AW      = 10,   // 坐标位宽
    parameter RING_T  = 2 ,   // 圆环半宽（像素）
    parameter CROSS_L = 12,   // 十字臂长（像素）
    parameter CROSS_T = 1     // 十字线半宽（像素）
)(
    input                valid ,   // 边界框有效
    input      [AW-1:0]  x     ,   // 当前像素 x
    input      [AW-1:0]  y     ,   // 当前像素 y
    input      [AW-1:0]  bl    ,   // 左
    input      [AW-1:0]  br    ,   // 右
    input      [AW-1:0]  bt    ,   // 上
    input      [AW-1:0]  bb    ,   // 下
    input      [AW-1:0]  cx    ,   // 圆心 x
    input      [AW-1:0]  cy    ,   // 圆心 y
    output               draw      // 1 = 这个像素要画标记
);

//localparam define
localparam DW2 = 2*AW + 2;        // 平方值位宽（800^2 = 640000 -> 20bit，留 2bit 余量）

//wire define
// 由边界框推半径：(宽 + 高) / 4
wire [AW:0]  w    = {1'b0,br} - {1'b0,bl} + 1'b1;
wire [AW:0]  h    = {1'b0,bb} - {1'b0,bt} + 1'b1;
wire [AW:0]  rr   = (w + h) >> 2;
wire [AW:0]  r_in = (rr > RING_T) ? (rr - RING_T) : {(AW+1){1'b0}};
wire [AW:0]  r_ou = rr + RING_T;

wire [DW2-1:0] in2  = r_in * r_in;
wire [DW2-1:0] out2 = r_ou * r_ou;

// 像素相对圆心的带符号偏移
wire signed [AW:0] dx = $signed({1'b0,x}) - $signed({1'b0,cx});
wire signed [AW:0] dy = $signed({1'b0,y}) - $signed({1'b0,cy});
wire [DW2-1:0]     d2 = dx*dx + dy*dy;

wire on_ring = (d2 >= in2) && (d2 <= out2);

// 十字（用绝对值比较，不用开根号）
wire [AW:0] adx = dx[AW] ? (~dx + 1'b1) : dx;
wire [AW:0] ady = dy[AW] ? (~dy + 1'b1) : dy;

wire on_h = (ady <= CROSS_T) && (adx <= CROSS_L);   // 横臂
wire on_v = (adx <= CROSS_T) && (ady <= CROSS_L);   // 竖臂

//*****************************************************
//**                    main code
//*****************************************************

assign draw = valid && (on_ring || on_h || on_v);

endmodule
