//****************************************Copyright (c)***********************************//
// File name:           armor_vision
// Descriptions:        视觉管线顶层（红/蓝装甲板辨识 + 边界框 + 中心十字）
//
//   数据来源：DDR3 读出的像素串流（rddata / rdata_req / rd_vsync）
//   数据去向：送到 lcd_rgb_top 显示
//
//   管线：
//     (1) 颜色分割（红 or 蓝，按键切换）           color_seg
//     (2) 形态学闭运算 = 膨胀 -> 腐蚀             morph_nxn x2
//     (3) 原图延迟 N-1 行/像素（与形态学位移对齐） video_delay
//     (4) 列投影 + 灯条配对 + 边界框              proj_bond
//     (5) 叠加边界框 + 中心十字                   overlay_box
//     (6) 显示合成（原图变暗+标记 / 纯二值）      本档
//
//   【输入对齐】rddata 比 rdata_req 慢一拍（ddr3_fifo_ctrl 的 rddata 是寄存器输出），
//   所以本模块先把 (data_in, de, x) 打一拍，让数据与坐标严格对齐，
//   后级所有模块都在这一拍后的时序上工作。
//----------------------------------------------------------------------------------------
//****************************************************************************************//
`timescale 1ns / 1ps

module armor_vision #(
    parameter IMG_W       = 800,          // 图像宽度（= LCD 宽度，1:1 不需缩放）
    parameter AW          = 10 ,          // 坐标位宽
    parameter MORPH_N     = 9  ,          // 形态学窗口大小（奇数；dart 用 9，可改 5/3）
    parameter CLK_FREQ    = 25_000_000,   // 像素时钟频率（4.3 吋 800x480 -> 25MHz）
    parameter LUM_MIN_SUM = 150,          // 亮度下限（见 color_seg）
    parameter HIST_TH     = 48 ,          // 栏投影阈值（见 proj_bond）
    parameter MIN_W       = 6  ,          // 灯条最小宽度
    parameter MAX_W       = 240,          // 灯条最大宽度
    parameter MIN_GAP     = 10 ,          // 两灯条最小间距
    parameter MAX_GAP     = 520,          // 两灯条最大间距
    parameter BOX_THICK   = 3             // 框线宽度
)(
    input                clk        ,   // 像素时钟（lcd_clk）
    input                rst_n      ,   // 复位
    input                vsync      ,   // 帧起始脉冲（rd_vsync）
    input                de         ,   // 像素有效（rdata_req）
    input      [15:0]    data_in    ,   // 像素数据（rddata）
    input      [3:0]     key        ,   // 按键（低电平有效）
    output     [15:0]    data_out   ,   // 处理后像素（送 LCD）
    output     [3:0]     led        ,   // LED 指示（低电平点亮）
    // 检测结果（观测/调试用）
    output               bond_valid ,
    output     [AW-1:0]  center_x   ,
    output     [AW-1:0]  center_y
);

//localparam define
localparam SGUARD  = MORPH_N - 1;       // 形态学造成的空间位移
localparam Y_GUARD = 2*SGUARD;          // 顶端无效行数（两级形态学）

//reg define
reg  [AW-1:0] x_cnt  ;   // 输入端 x 计数
reg  [AW-1:0] y_cnt  ;   // 对齐后的 y 计数（有效行由 1 起算）
reg           de_seen;   // 本帧是否已经出现过有效像素
reg           de_d    ;  // de 延迟一拍（找行尾）
reg           de_v   ;   // 对齐后的有效信号
reg  [AW-1:0] x_v    ;   // 对齐后的 x
reg  [15:0]   data_v ;   // 对齐后的像素

//wire define
wire          mode     ;   // 0 = 红，1 = 蓝
wire [7:0]    thresh   ;   // 颜色阈值
wire          disp_bin ;   // 显示模式
wire          seg_mask ;   // 颜色分割结果
wire          dil_mask ;   // 膨胀结果
wire          ero_mask ;   // 腐蚀结果（= 闭运算结果）
wire [15:0]   img_d    ;   // 与二值图对齐的原图
wire [AW-1:0] bl, br, bt, bb;
wire          draw     ;

//*****************************************************
//**                    main code
//*****************************************************

//-------------------------------------------------------
// 输入对齐：把 (data_in, de) 打一拍，并用打拍后的 de 产生坐标
//   x_v : 一行内 0 ~ IMG_W-1
//   y_v : 有效行由 1 起算（只在有数据的行计数，所以不受垂直消隐行数影响）
//-------------------------------------------------------
always @(posedge clk or negedge rst_n) begin
    if(!rst_n) begin
        x_cnt   <= {AW{1'b0}};
        y_cnt   <= {AW{1'b0}};
        de_seen <= 1'b0;
        de_d    <= 1'b0;
        de_v    <= 1'b0;
        x_v     <= {AW{1'b0}};
        data_v  <= 16'd0;
    end
    else begin
        // 输入端 x 计数（以 rdata_req 为准）
        if(!de)
            x_cnt <= {AW{1'b0}};
        else
            x_cnt <= x_cnt + 1'b1;

        // 打一拍对齐 fifo 输出
        de_v   <= de;
        data_v <= data_in;
        x_v    <= x_cnt;      // 与 data_v 同一个像素

        // y 计数：本帧第一个有效像素所在的行 = 第 1 行，之后在行尾进位
        de_d <= de_v;
        if(vsync) begin
            y_cnt   <= {AW{1'b0}};
            de_seen <= 1'b0;
        end
        else if(de_v && !de_seen) begin
            y_cnt   <= {{(AW-1){1'b0}}, 1'b1};
            de_seen <= 1'b1;
        end
        else if(de_d && !de_v) begin
            y_cnt <= y_cnt + 1'b1;
        end
    end
end

//-------------------------------------------------------
// (1) 颜色分割 / 按键参数
//-------------------------------------------------------
vision_cfg #(
    .CLK_FREQ (CLK_FREQ)
) u_vision_cfg (
    .clk      (clk     ),
    .rst_n    (rst_n   ),
    .key      (key     ),
    .mode     (mode    ),
    .thresh   (thresh  ),
    .disp_bin (disp_bin)
);

color_seg #(
    .LUM_MIN_SUM (LUM_MIN_SUM)
) u_color_seg (
    .rgb565 (data_v   ),
    .mode   (mode     ),
    .thresh (thresh   ),
    .mask   (seg_mask )
);

//-------------------------------------------------------
// (2) 形态学：膨胀 -> 腐蚀 = 闭运算（填补灯条内小空洞、把小断点连起来）
//-------------------------------------------------------
morph_nxn #(
    .N      (MORPH_N),
    .WIDTH  (IMG_W  ),
    .AW     (AW     ),
    .DILATE (1      )
) u_dilate (
    .clk   (clk      ),
    .rst_n (rst_n    ),
    .de    (de_v     ),
    .x     (x_v      ),
    .din   (seg_mask ),
    .dout  (dil_mask )
);

morph_nxn #(
    .N      (MORPH_N),
    .WIDTH  (IMG_W  ),
    .AW     (AW     ),
    .DILATE (0      )
) u_erode (
    .clk   (clk      ),
    .rst_n (rst_n    ),
    .de    (de_v     ),
    .x     (x_v      ),
    .din   (dil_mask ),
    .dout  (ero_mask )
);

// 顶端 2*(N-1) 行行缓冲还没填满（内容是上一帧的残留），直接视为 0
wire mask_d = ero_mask & (y_cnt > Y_GUARD);

//-------------------------------------------------------
// (3) 原图延迟：形态学让二值图往右下偏移 N-1，原图也延迟 N-1 行/像素
//-------------------------------------------------------
video_delay #(
    .DW     (16     ),
    .WIDTH  (IMG_W  ),
    .LINES  (SGUARD ),
    .PIXELS (SGUARD ),
    .AW     (AW     )
) u_video_delay (
    .clk   (clk    ),
    .rst_n (rst_n  ),
    .de    (de_v   ),
    .x     (x_v    ),
    .din   (data_v ),
    .dout  (img_d  )
);

//-------------------------------------------------------
// (4) 列投影 + 灯条配对 + 边界框
//-------------------------------------------------------
proj_bond #(
    .WIDTH   (IMG_W   ),
    .AW      (AW      ),
    .HIST_TH (HIST_TH ),
    .MIN_W   (MIN_W   ),
    .MAX_W   (MAX_W   ),
    .MIN_GAP (MIN_GAP ),
    .MAX_GAP (MAX_GAP ),
    .Y_GUARD (Y_GUARD )
) u_proj_bond (
    .clk        (clk        ),
    .rst_n      (rst_n      ),
    .vsync      (vsync      ),
    .de         (de_v       ),
    .x          (x_v        ),
    .y          (y_cnt      ),
    .mask       (mask_d     ),
    .bond_valid (bond_valid ),
    .bond_l     (bl         ),
    .bond_r     (br         ),
    .bond_t     (bt         ),
    .bond_b     (bb         ),
    .center_x   (center_x   ),
    .center_y   (center_y   )
);

//-------------------------------------------------------
// (5) 叠加边界框 + 中心十字
//-------------------------------------------------------
overlay_box #(
    .AW    (AW        ),
    .THICK (BOX_THICK )
) u_overlay_box (
    .valid (bond_valid),
    .x     (x_v       ),
    .y     (y_cnt     ),
    .bl    (bl        ),
    .br    (br        ),
    .bt    (bt        ),
    .bb    (bb        ),
    .cx    (center_x  ),
    .cy    (center_y  ),
    .draw  (draw      )
);

//-------------------------------------------------------
// (6) 显示合成
//   模式 0：原图亮度减半 + 命中的灯条保持原色 + 绿色框/十字
//   模式 1：纯二值图（白 = 命中）+ 绿色框/十字
//-------------------------------------------------------
wire [15:0] dim_pix = {1'b0, img_d[15:12],    // R5 减半
                       1'b0, img_d[10:6],     // G6 减半
                       1'b0, img_d[4:1]};     // B5 减半

wire [15:0] disp_pix = disp_bin ? (mask_d ? 16'hFFFF : 16'h0000)
                                : (mask_d ? img_d  : dim_pix);

assign data_out = draw ? 16'h07E0 : disp_pix;   // RGB565 绿色

//-------------------------------------------------------
// LED 指示（板上低电平点亮）
//   led[0] : 红色模式    led[1] : 蓝色模式
//   led[2] : 检测到装甲板 led[3] : 心跳
//-------------------------------------------------------
reg [23:0] hb_cnt;
always @(posedge clk or negedge rst_n) begin
    if(!rst_n) hb_cnt <= 24'd0;
    else       hb_cnt <= hb_cnt + 1'b1;
end

wire red_mode  = ~mode;
wire blue_mode =  mode;

assign led[0] = ~red_mode;
assign led[1] = ~blue_mode;
assign led[2] = ~bond_valid;
assign led[3] = ~hb_cnt[23];

endmodule
