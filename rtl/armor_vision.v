//****************************************Copyright (c)***********************************//
// File name:           armor_vision
// Descriptions:        视觉管线顶层（绿色圆形靶标识别 + 红色圆环 / 瞄准点十字）
//
//   飞镖（dart）的靶标是【一个大绿色圆形灯】。本管线把 DDR3 读出的 RGB565 像素流
//   （rddata / rdata_req / rd_vsync）处理一遍，再送给 lcd_rgb_top 显示。
//
//   管线：
//     (1) 绿色分割         绝对判据 + 相对饱和度闸（抗反光）              color_seg
//     (2) 形态学闭运算      9x9 膨胀 -> 9x9 腐蚀（填小洞、去碎点）         morph_nxn x2
//     (3) 原图延迟          延后 8 行 + 8 像素，抵消形态学窗口的空间偏移   video_delay
//     (4) 双投影找绿块      X/Y 直方图取【外沿】-> 边界框 / 圆心 / 瞄准点  proj_bond
//     (5) 叠印标记          红色圆环 + 瞄准点十字                         overlay_box
//     (6) 数码管            显示三个阈值 / 目标尺寸                       seg_display
//     (7) 显示合成          原图变暗 + 命中处原色（或纯二值）+ 红色标记
//
//   【抗反光】**默认靠算法**（两条尺度无关的措施，不依赖任何相机设置）：
//     a) 算法端（主力）：color_seg 的相对饱和度闸 —— 对自动曝光 / 自动白平衡的漂移天然免疫
//     b) 算法端：proj_bond 的「取外沿」投影 —— 不会被反射在灯上打出的洞切成两半
//     c) 相机端（**可选，默认关闭**）：i2c_ov5640_rgb565_cfg.v 的 CAM_LOCK_EN
//        打开后把曝光 / 增益锁死（dart 工程就是固定曝光 + 固定增益）。
//        注意：固定曝光值必须按现场亮度标定，标错会「黑屏」——
//        因为 lcd_driver.v 里 lcd_bl 写死 1'b1（背光常亮），「黑」只能是像素数据本身黑。
//
//   【瞄准点】靶标的实际打击点在绿色灯上方一点，所以 proj_bond 会把圆心往上偏移
//     AIM_H_Q8/256 × 宽度 个像素（默认 1/4）。这个偏移**不需要知道距离**：
//     同一个物理偏移 Δh 在图像里是 f·Δh/D，而灯的表观宽度 W = f·Dt/D，
//     两式相除得 像素偏移 = W · (Δh/Dt) —— 距离 D 已经被 W 隐含掉了。
//
//   参数与按键说明见 README.md 与 doc/vision_pipeline.md。
//
//   【输入输出约定】rddata 与 rdata_req 是一拍一像素（ddr3_fifo_ctrl 的 rddata 是寄存器输出），
//   所以本模块先把 (data_in, de, x) 打一拍再送进管线，后面所有模块都在这一拍上工作。
//----------------------------------------------------------------------------------------
//****************************************************************************************//

`timescale 1ns / 1ps

module armor_vision #(
    parameter IMG_W       = 800        ,   // 图像宽（= LCD 宽度，1:1 不缩放）
    parameter IMG_H       = 480        ,   // 图像高
    parameter AW          = 10         ,   // 坐标位宽
    parameter MORPH_N     = 9          ,   // 形态学窗口大小（9 -> 偏移 8 行/像素）
    parameter CLK_FREQ    = 25_000_000 ,   // 工作时钟频率
    parameter TH_G_DEF    = 8'd100     ,   // TH_G   默认值（借自 dart 的 400>>2）
    parameter TH_GR_DEF   = 8'd32      ,   // TH_G-R 默认值（借自 dart 的 130>>2）
    parameter TH_GB_DEF   = 8'd32      ,   // TH_G-B 默认值（借自 dart 的 130>>2）
    parameter [7:0] REL_SAT_PCT = 8'd20,   // 相对饱和度下限（%）；0 = 关闭抗反光闸
    parameter TH_MIN      = 4          ,   // 投影阈值：一列/一行的最少亮点数
    parameter MIN_SIZE    = 24         ,   // 目标最小边长
    parameter [7:0] AIM_H_Q8 = 8'd64   ,   // 瞄准点在灯心上方 = 宽度 x AIM_H_Q8/256
    parameter RING_T      = 2          ,   // 圆环半宽（像素）
    parameter CROSS_L     = 12             // 十字臂长（像素）
)(
    input                clk        ,   // 工作时钟（lcd_clk）
    input                rst_n      ,   // 复位
    input                vsync      ,   // 帧开始脉冲（rd_vsync）
    input                de         ,   // 行数据有效（rdata_req）
    input      [15:0]    data_in    ,   // 输入像素（rddata）
    input      [3:0]     key        ,   // 按键（低电平有效）
    output     [15:0]    data_out   ,   // 输出像素（送 LCD）
    output     [3:0]     led        ,   // LED 指示（低电平点亮）
    output     [5:0]     seg_sel    ,   // 数码管位选（低电平选通）
    output     [7:0]     seg_led    ,   // 数码管段码（低电平点亮）
    // 调试观察 / 后续送云台用
    output               bond_valid ,   // 检测到目标
    output     [AW-1:0]  center_x   ,   // 绿圆灯心 x
    output     [AW-1:0]  center_y   ,   // 绿圆灯心 y
    output     [AW-1:0]  aim_x      ,   // 瞄准点 x（= 灯心 x）
    output     [AW-1:0]  aim_y          // 瞄准点 y（灯心往上偏一点）
);

//localparam define
localparam SGUARD  = MORPH_N - 1;       // 形态学造成的空间偏移
localparam Y_GUARD = 2*SGUARD;          // 顶部无效行数（两级形态学的暖机）

//reg define
reg  [AW-1:0] x_cnt  ;   // 输入计数 x
reg  [AW-1:0] y_cnt  ;   // 输入计数 y（有效行从 1 起算）
reg           de_seen;   // 本帧是否已经见过有效行
reg           de_d   ;   // de 延迟一拍（用于行尾定位）
reg           de_v   ;   // 打一拍的 de
reg  [AW-1:0] x_v    ;   // 打一拍的 x
reg  [15:0]   data_v ;   // 打一拍的像素

//wire define
wire [1:0]    sel      ;   // 当前选中的阈值编号
wire [7:0]    th_g     ;   // TH_G
wire [7:0]    th_gr    ;   // TH_G-R
wire [7:0]    th_gb    ;   // TH_G-B
wire          disp_bin ;   // 显示模式
wire          seg_mask ;   // 绿色分割结果
wire          dil_mask ;   // 膨胀结果
wire          ero_mask ;   // 腐蚀结果（= 闭运算输出）
wire [15:0]   img_d    ;   // 延迟后的原图
wire [AW-1:0] bl, br, bt, bb;
wire [AW:0]   bond_w   ;   // 边界框宽度
wire          draw     ;   // 叠加标记
wire          mask_d   ;   // 顶部暖机区强制为 0 的二值图

//*****************************************************
//**                    main code
//*****************************************************

//-------------------------------------------------------
// 输入对齐：把 (data_in, de) 打一拍，后面都用打拍后的 de 做行内计数
//   x_v : 一行内 0 ~ IMG_W-1
//   y_cnt : 有效行从 1 起算（只用于数据中间部分，不影响垂直方向对齐）
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
        // 行内 x 计数：以 rdata_req 为准
        if(!de)
            x_cnt <= {AW{1'b0}};
        else
            x_cnt <= x_cnt + 1'b1;

        // 打一拍对齐 fifo 输出
        de_v   <= de;
        data_v <= data_in;
        x_v    <= x_cnt;      // 与 data_v 同一拍

        // y 计数：本帧第一个有效行所在拍 = 第 1 行，之后每个行尾加一
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
// (1) 参数配置：三颗按键映射到三个阈值 + 显示模式
//-------------------------------------------------------
vision_cfg #(
    .CLK_FREQ  (CLK_FREQ ),
    .TH_G_DEF  (TH_G_DEF ),
    .TH_GR_DEF (TH_GR_DEF),
    .TH_GB_DEF (TH_GB_DEF)
) u_vision_cfg (
    .clk      (clk     ),
    .rst_n    (rst_n   ),
    .key      (key     ),
    .sel      (sel     ),
    .th_g     (th_g    ),
    .th_gr    (th_gr   ),
    .th_gb    (th_gb   ),
    .disp_bin (disp_bin)
);

//-------------------------------------------------------
// (2) 绿色分割：绝对判据 + 相对饱和度闸（抗反光）
//-------------------------------------------------------
color_seg #(
    .REL_SAT_PCT (REL_SAT_PCT)
) u_color_seg (
    .rgb565 (data_v   ),
    .th_g   (th_g     ),
    .th_gr  (th_gr    ),
    .th_gb  (th_gb    ),
    .mask   (seg_mask )
);

//-------------------------------------------------------
// (3) 形态学：膨胀 -> 腐蚀 = 闭运算（填绿圆内部小洞、去碎点）
//     两级各偏移 N-1，合计 2*(N-1) = 16 行/像素
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

// 顶部 2*(N-1) 行行缓冲还没填满，这一段的二值输出无意义，直接按 0 处理
assign mask_d = ero_mask & (y_cnt > Y_GUARD);

//-------------------------------------------------------
// (4) 原图延迟：形态学让二值图整体往右下偏 N-1
//     把原图也延后 N-1 行 + N-1 像素，屏幕上就对齐了
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
// (5) 双投影找绿块（取外沿，抗反光洞）+ 圆心 + 瞄准点
//-------------------------------------------------------
proj_bond #(
    .WIDTH    (IMG_W      ),
    .HEIGHT   (IMG_H      ),
    .AW       (AW         ),
    .Y_GUARD  (Y_GUARD    ),
    .TH_MIN   (TH_MIN     ),
    .MIN_SIZE (MIN_SIZE   ),
    .AIM_H_Q8 (AIM_H_Q8   )
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
    .center_y   (center_y   ),
    .aim_x      (aim_x      ),
    .aim_y      (aim_y      )
);

assign bond_w = {1'b0, br} - {1'b0, bl} + 1'b1;

//-------------------------------------------------------
// (6) 叠印：红色圆环（套住灯）+ 瞄准点十字
//-------------------------------------------------------
overlay_box #(
    .AW      (AW     ),
    .RING_T  (RING_T ),
    .CROSS_L (CROSS_L)
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
    .ax    (aim_x     ),
    .ay    (aim_y     ),
    .draw  (draw      )
);

//-------------------------------------------------------
// (7) 显示合成
//   模式 0：原图变暗 + 命中的像素显示原色 + 红色标记
//   模式 1：纯二值图（命中 = 白）
//-------------------------------------------------------
wire [15:0] dim_pix = {1'b0, img_d[15:12],    // R5 减半
                       1'b0, img_d[10:6],     // G6 减半
                       1'b0, img_d[4:1]};     // B5 减半

wire [15:0] disp_pix = disp_bin ? (mask_d ? 16'hFFFF : 16'h0000)
                                : (mask_d ? img_d  : dim_pix);

assign data_out = draw ? 16'hF800 : disp_pix;   // RGB565 纯红

//-------------------------------------------------------
// (8) 6 位数码管：显示三个阈值 / 目标宽度
//-------------------------------------------------------
seg_display #(
    .CLK_FREQ (CLK_FREQ)
) u_seg_display (
    .clk        (clk       ),
    .rst_n      (rst_n     ),
    .sel        (sel       ),
    .th_g       (th_g      ),
    .th_gr      (th_gr     ),
    .th_gb      (th_gb     ),
    .bond_valid (bond_valid),
    .bond_w     (bond_w    ),
    .disp_bin   (disp_bin  ),
    .seg_sel    (seg_sel   ),
    .seg_led    (seg_led   )
);

//-------------------------------------------------------
// (9) LED 指示（板上低电平点亮）
//   led[0] : 当前在调 TH_G
//   led[1] : 当前在调 TH_G-R
//   led[2] : 当前在调 TH_G-B
//   led[3] : 检测到目标常亮；未检测到时 1.5Hz 闪烁（顺便当心跳）
//-------------------------------------------------------
reg [23:0] hb_cnt;
always @(posedge clk or negedge rst_n) begin
    if(!rst_n) hb_cnt <= 24'd0;
    else       hb_cnt <= hb_cnt + 1'b1;
end

wire hb = hb_cnt[23];      // 25MHz 下约 0.34s 翻转 -> 约 1.5Hz

assign led[0] = ~(sel == 2'd0);
assign led[1] = ~(sel == 2'd1);
assign led[2] = ~(sel == 2'd2);
assign led[3] = ~(bond_valid ? 1'b1 : hb);

endmodule
