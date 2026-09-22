//****************************************Copyright (c)***********************************//
// File name:           color_seg
// Descriptions:        顏色分割（二值化）：紅 / 藍 二選一（純組合邏輯）
//
//   輸入為 RGB565，先展成 8bit：R5 -> R8、G6 -> G8、B5 -> B8
//   紅色判據： (R8 - G8 > T) 且 (R8 - B8 > T)
//   藍色判據： (B8 - G8 > T) 且 (B8 - R8 > T)
//   再加上亮度閘（R8+G8+B8 >= LUM_MIN_SUM），避免暗部雜訊被誤判。
//
//   【為什麼不寫成時序邏輯】整條視覺管線都以「當拍像素的 x」定址行緩衝，
//   本模組若多打一拍，後面形態學的行緩衝位址就會差一格。
//   25MHz 下組合延遲（約 3 級 LUT）完全沒有壓力。
//----------------------------------------------------------------------------------------
//****************************************************************************************//
`timescale 1ns / 1ps

module color_seg #(
    parameter LUM_MIN_SUM = 150          // 亮度下限（R8+G8+B8 之和，0 = 關閉）
)(
    input      [15:0] rgb565 ,           // RGB565 像素
    input             mode   ,           // 0 = 紅，1 = 藍
    input      [7:0]  thresh ,           // 顏色門檻（可按鍵調整）
    output            mask               // 1 = 命中
);

//wire define
wire [4:0] r5 = rgb565[15:11];
wire [5:0] g6 = rgb565[10:5] ;
wire [4:0] b5 = rgb565[4:0]  ;

// 5/6 bit 展成 8bit（高位補齊，等效 x*8 + x/4）
wire [7:0] r8 = {r5, r5[4:2]};
wire [7:0] g8 = {g6, g6[5:4]};
wire [7:0] b8 = {b5, b5[4:2]};

// 帶符號差值（9bit 足夠：255-0=255，用 10bit 更保險）
wire signed [9:0] rg = $signed({1'b0,r8}) - $signed({1'b0,g8});
wire signed [9:0] rb = $signed({1'b0,r8}) - $signed({1'b0,b8});
wire signed [9:0] bg = $signed({1'b0,b8}) - $signed({1'b0,g8});
wire signed [9:0] br = $signed({1'b0,b8}) - $signed({1'b0,r8});
wire signed [9:0] thr = $signed({2'b00, thresh});

// 亮度閘
wire [9:0] lum_sum = {2'b00,r8} + {2'b00,g8} + {2'b00,b8};
wire       lum_ok  = (lum_sum >= LUM_MIN_SUM);

// 顏色判據
wire red_ok  = (rg > thr) && (rb > thr);
wire blue_ok = (bg > thr) && (br > thr);

//*****************************************************
//**                    main code
//*****************************************************

assign mask = (mode ? blue_ok : red_ok) && lum_ok;

endmodule
