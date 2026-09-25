//****************************************Copyright (c)***********************************//
// File name:           overlay_box
// Descriptions:        在像素流上叠印【红色圆环 + 瞄准点十字】（纯组合逻辑）
//
//   - 圆环：套住识别到的绿色圆灯（让肉眼确认「有没有认到、认到多大」）
//           半径 R = (宽 + 高) / 4，环宽 ±RING_T 像素
//   - 十字：画在【瞄准点】上（proj_bond 算出来的 aim_x / aim_y）
//           瞄准点在灯心上方一点，所以正常情况下十字会在圆环圆心上方浮动
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
    parameter CROSS_L = 12,   // 十字臂长度（像素）
    parameter CROSS_T = 1     // 十字线半宽（像素）
)(
    input                valid ,   // 外框有效
    input      [AW-1:0]  x     ,   // 当前像素 x
    input      [AW-1:0]  y     ,   // 当前像素 y
    input      [AW-1:0]  bl    ,   // 左
    input      [AW-1:0]  br    ,   // 右
    input      [AW-1:0]  bt    ,   // 上
    input      [AW-1:0]  bb    ,   // 下
    input      [AW-1:0]  cx    ,   // 圆心 x（外框中心）
    input      [AW-1:0]  cy    ,   // 圆心 y（外框中心）
    input      [AW-1:0]  ax    ,   // 瞄准点 x（当前帧几何瞄准点）
    input      [AW-1:0]  ay    ,   // 瞄准点 y（当前帧几何瞄准点）
    input      [AW-1:0]  ring_t ,   // 圆环宽度（像素，运行时可变；UART 0x06）
    input      [AW-1:0]  pvx   ,   // 预测瞄准点 x
    input      [AW-1:0]  pvy   ,   // 预测瞄准点 y
    input                pv_on ,   // 1 = 画预测十字（目标在动时才画）
    output               draw  ,   // 1 = 圆环 / 当前瞄准十字
    output               draw_p    // 1 = 预测十字（画面合成为黄色）
);

//localparam define
localparam DW2 = 2*AW + 2;        // 平方值位宽（800^2 = 640000 -> 20bit，留 2bit 余量）

//wire define
// 由边界框推半径：(宽 + 高) / 4
wire [AW:0]  w    = {1'b0,br} - {1'b0,bl} + 1'b1;
wire [AW:0]  h    = {1'b0,bb} - {1'b0,bt} + 1'b1;
wire [AW:0]  rr   = (w + h) >> 2;
wire [AW:0]  r_in = (rr > {1'b0, ring_t}) ? (rr - {1'b0, ring_t}) : {(AW+1){1'b0}};
wire [AW:0]  r_ou = rr + {1'b0, ring_t};

wire [DW2-1:0] in2  = r_in * r_in;
wire [DW2-1:0] out2 = r_ou * r_ou;

// 像素相对【圆心】的带符号偏移（圆环用）
wire signed [AW:0] dx = $signed({1'b0,x}) - $signed({1'b0,cx});
wire signed [AW:0] dy = $signed({1'b0,y}) - $signed({1'b0,cy});
wire [DW2-1:0]     d2 = dx*dx + dy*dy;

wire on_ring = (d2 >= in2) && (d2 <= out2);

// 像素相对【瞄准点】的带符号偏移（十字用，用绝对值比较，不用开根号）
wire signed [AW:0] ax_d = $signed({1'b0,x}) - $signed({1'b0,ax});
wire signed [AW:0] ay_d = $signed({1'b0,y}) - $signed({1'b0,ay});
wire [AW:0] aadx = ax_d[AW] ? (~ax_d + 1'b1) : ax_d;
wire [AW:0] aady = ay_d[AW] ? (~ay_d + 1'b1) : ay_d;

wire on_h = (aady <= CROSS_T) && (aadx <= CROSS_L);   // 横臂
wire on_v = (aadx <= CROSS_T) && (aady <= CROSS_L);   // 竖臂

//*****************************************************
//**                    main code
//*****************************************************

//  预测十字：与瞄准十字同一套曼哈顿距离比较（省乘法器）
//  注意：pv_on=0（静止 / 预测关闭 / 历史不足）时 draw_p 恒为 0，
//  所以静止目标下的像素期望与改动前逐点一致。
wire signed [AW:0] pvx_d = $signed({1'b0,x}) - $signed({1'b0,pvx});
wire signed [AW:0] pvy_d = $signed({1'b0,y}) - $signed({1'b0,pvy});
wire [AW:0] pvdx = pvx_d[AW] ? (~pvx_d + 1'b1) : pvx_d;
wire [AW:0] pvdy = pvy_d[AW] ? (~pvy_d + 1'b1) : pvy_d;
wire pv_h = (pvdy <= CROSS_T) && (pvdx <= CROSS_L);
wire pv_v = (pvdx <= CROSS_T) && (pvdy <= CROSS_L);

assign draw   = valid && (on_ring || on_h || on_v);
assign draw_p = pv_on && valid && (pv_h || pv_v);

endmodule
