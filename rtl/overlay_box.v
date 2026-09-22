//****************************************Copyright (c)***********************************//
// File name:           overlay_box
// Descriptions:        在像素串流上疊加「邊界框 + 中心十字」（純組合邏輯）
//
//   座標系與二值圖相同（同一個像素串流），所以框一定貼著看到的那兩根燈條。
//   THICK 為線寬（像素）。
//----------------------------------------------------------------------------------------
//****************************************************************************************//
`timescale 1ns / 1ps

module overlay_box #(
    parameter AW    = 10,   // 座標位寬
    parameter THICK = 3     // 線寬
)(
    input                valid ,   // 邊界框有效
    input      [AW-1:0]  x     ,   // 當前像素 x
    input      [AW-1:0]  y     ,   // 當前像素 y
    input      [AW-1:0]  bl    ,   // 框左
    input      [AW-1:0]  br    ,   // 框右
    input      [AW-1:0]  bt    ,   // 框上
    input      [AW-1:0]  bb    ,   // 框下
    input      [AW-1:0]  cx    ,   // 中心 x
    input      [AW-1:0]  cy    ,   // 中心 y
    output               draw      // 1 = 此像素要畫框/十字
);

//wire define
wire in_x = (x >= bl) && (x <= br);
wire in_y = (y >= bt) && (y <= bb);

// 四條邊
wire on_h = in_x && ((y < (bt + THICK)) || (y > (bb - THICK)));
wire on_v = in_y && ((x < (bl + THICK)) || (x > (br - THICK)));

// 中心十字
wire on_c = (in_x && (y >= (cy - THICK)) && (y <= (cy + THICK))) ||
            (in_y && (x >= (cx - THICK)) && (x <= (cx + THICK)));

//*****************************************************
//**                    main code
//*****************************************************

assign draw = valid && (on_h || on_v || on_c);

endmodule
