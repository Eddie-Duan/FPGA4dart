//****************************************Copyright (c)***********************************//
// File name:           overlay_box
// Descriptions:        在像素串流上叠加“边界框 + 中心十字”（纯组合逻辑）
//
//   坐标系与二值图相同（同一个像素串流），所以框一定贴著看到的那两根灯条。
//   THICK 为线宽（像素）。
//----------------------------------------------------------------------------------------
//****************************************************************************************//
`timescale 1ns / 1ps

module overlay_box #(
    parameter AW    = 10,   // 坐标位宽
    parameter THICK = 3     // 线宽
)(
    input                valid ,   // 边界框有效
    input      [AW-1:0]  x     ,   // 当前像素 x
    input      [AW-1:0]  y     ,   // 当前像素 y
    input      [AW-1:0]  bl    ,   // 框左
    input      [AW-1:0]  br    ,   // 框右
    input      [AW-1:0]  bt    ,   // 框上
    input      [AW-1:0]  bb    ,   // 框下
    input      [AW-1:0]  cx    ,   // 中心 x
    input      [AW-1:0]  cy    ,   // 中心 y
    output               draw      // 1 = 此像素要画框/十字
);

//wire define
wire in_x = (x >= bl) && (x <= br);
wire in_y = (y >= bt) && (y <= bb);

// 四条边
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
