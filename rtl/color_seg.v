//****************************************Copyright (c)***********************************//
// File name:           color_seg
// Descriptions:        颜色分割（二值化）：红 / 蓝 二选一（纯组合逻辑）
//
//   输入为 RGB565，先展成 8bit：R5 -> R8、G6 -> G8、B5 -> B8
//   红色判据： (R8 - G8 > T) 且 (R8 - B8 > T)
//   蓝色判据： (B8 - G8 > T) 且 (B8 - R8 > T)
//   再加上亮度闸（R8+G8+B8 >= LUM_MIN_SUM），避免暗部噪声被误判。
//
//   【为什么不写成时序逻辑】整条视觉管线都以“当拍像素的 x”定址行缓冲，
//   本模块若多打一拍，后面形态学的行缓冲地址就会差一格。
//   25MHz 下组合延迟（约 3 级 LUT）完全没有压力。
//----------------------------------------------------------------------------------------
//****************************************************************************************//
`timescale 1ns / 1ps

module color_seg #(
    parameter LUM_MIN_SUM = 150          // 亮度下限（R8+G8+B8 之和，0 = 关闭）
)(
    input      [15:0] rgb565 ,           // RGB565 像素
    input             mode   ,           // 0 = 红，1 = 蓝
    input      [7:0]  thresh ,           // 颜色阈值（可按键调整）
    output            mask               // 1 = 命中
);

//wire define
wire [4:0] r5 = rgb565[15:11];
wire [5:0] g6 = rgb565[10:5] ;
wire [4:0] b5 = rgb565[4:0]  ;

// 5/6 bit 展成 8bit（高位补齐，等效 x*8 + x/4）
wire [7:0] r8 = {r5, r5[4:2]};
wire [7:0] g8 = {g6, g6[5:4]};
wire [7:0] b8 = {b5, b5[4:2]};

// 带符号差值（9bit 足够：255-0=255，用 10bit 更保险）
wire signed [9:0] rg = $signed({1'b0,r8}) - $signed({1'b0,g8});
wire signed [9:0] rb = $signed({1'b0,r8}) - $signed({1'b0,b8});
wire signed [9:0] bg = $signed({1'b0,b8}) - $signed({1'b0,g8});
wire signed [9:0] br = $signed({1'b0,b8}) - $signed({1'b0,r8});
wire signed [9:0] thr = $signed({2'b00, thresh});

// 亮度闸
wire [9:0] lum_sum = {2'b00,r8} + {2'b00,g8} + {2'b00,b8};
wire       lum_ok  = (lum_sum >= LUM_MIN_SUM);

// 颜色判据
wire red_ok  = (rg > thr) && (rb > thr);
wire blue_ok = (bg > thr) && (br > thr);

//*****************************************************
//**                    main code
//*****************************************************

assign mask = (mode ? blue_ok : red_ok) && lum_ok;

endmodule
