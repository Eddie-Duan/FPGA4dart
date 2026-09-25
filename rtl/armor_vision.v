//****************************************Copyright (c)***********************************//
// File name:           armor_vision
// Descriptions:        视觉管线顶层（绿色圆形靶标识别 + 红色圆环 / 瞄准点十字）
//
//   飞镖（dart）的靶标是【一个大绿色圆形灯】。本管线把 DDR3 读出的 RGB565 像素流
//   （rddata / rdata_req / rd_vsync）处理一遍，再送给 lcd_rgb_top 显示。
//
//   管线：
//     (1) 中值预滤波        3x3 分离式中值（可选）                          median3x3
//     (2) 绿色分割          绝对判据 + 相对饱和度闸（抗反光）              color_seg
//     (3) 形态学闭运算      9x9 膨胀 -> 9x9 腐蚀（填小洞、去碎点）         morph_nxn x2
//     (4) 原图延迟          延后 8 行 + 8 像素，抵消形态学窗口的空间偏移   video_delay
//     (5) 团块跟踪          行程级连通团块 -> 外框/面积/形心/圆度/数量     blob_track
//     (6) 时序门控+跟踪     门控 + 持久性 + alpha-beta（可选）             track_ab
//     (7) 叠印标记          红色圆环 + 瞄准点十字                          overlay_box
//     (8) 数码管            显示三个阈值 / 目标尺寸                        seg_display
//     (9) 显示合成          原图变暗 + 命中处原色（或纯二值）+ 红色标记
//    (10) 仪表盘            帧率 / 帧周期 / 掩码像素数 / 命中率            vision_stat
//    (11) 自适应阈值        色度直方图分位数（可选）                       chroma_hist
//    (12) 自动曝光闭环      统计过曝比例调曝光（可选）                     aec_loop
//    (13) UART              结果上报 + 参数写入                            result_frame / reg_file
//    (14) OSD               数值叠加 + 直方图条形图（可选）                osd_text
//
//   【抗反光】默认靠算法（两条尺度无关的措施，不依赖任何相机设置）：
//     a) 算法端（主力）：color_seg 的相对饱和度闸 —— 对自动曝光 / 自动白平衡的漂移天然免疫
//     b) 算法端：blob_track 基于行程的团块跟踪 —— 不会被反射在灯上打出的洞切成两半
//     c) 相机端（**可选，默认关闭**）：i2c_ov5640_rgb565_cfg.v 的 CAM_LOCK_EN
//        打开后把曝光/增益锁死（dart 工程就是固定曝光 + 固定增益）。
//        注意：固定曝光值必须按现场亮度标定，标错会「黑屏」——
//        因为 lcd_driver.v 里 lcd_bl 写死 1'b1（背光常亮），「黑」只能是像素数据本身黑。
//     d) 更稳妥的做法是 aec_loop（AEC_EN）：让 PL 自己按过曝比例闭环调曝光，
//        不再依赖任何「拍脑袋猜的常数」。
//
//   【瞄准点】靶标的实际打击点在绿色灯上方一点，所以 blob_track 会把圆心往上偏移
//     AIM_H_Q8/256 × 宽度 个像素（默认 1/4）。这个偏移**不需要知道距离**：
//     同一个物理偏移 Δh 在图像里是 f·Δh/D，而灯的表观宽度 W = f·Dt/D，
//     两式相除得 像素偏移 = W · (Δh/Dt) —— 距离 D 已经被 W 隐含掉了。
//
//   【新增功能的开关】所有 P0~P8 的新功能都带独立开关，且**默认关闭**，
//     以保证默认行为与本轮改动前完全一致（可用作回退与二分定位）。
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
    parameter TH_G_DEF    = 8'd100     ,   // TH_G  默认值（借用 dart 的 400>>2）
    parameter TH_GR_DEF   = 8'd32      ,   // TH_G-R 默认值（借用 dart 的 130>>2）
    parameter TH_GB_DEF   = 8'd32      ,   // TH_G-B 默认值（借用 dart 的 130>>2）
    parameter [7:0] REL_SAT_PCT = 8'd20,   // 相对饱和度闸门限（%）；0 = 关闭该闸
    parameter TH_MIN      = 4          ,   // 投影峰值阈值（一行/一列的亮像素数）
    parameter MIN_SIZE    = 24         ,   // 目标最小边长
    //  瞄准点偏移 = 宽度 x AIM_H_Q8/256，Q0.8 定点。
    //  真实靶标：打击点在灯心上方 80mm、灯直径 55mm
    //  -> 256*80/55 = 372（= 1.449 倍灯直径，不是 1/4）。
    //  注意：必须 >= 9bit。写成 8bit 装不下 372，会被静默截断成 116（= 0.45 倍）。
    parameter [15:0] AIM_H_Q8 = 16'd372 ,
    parameter RING_T      = 2          ,   // 圆环宽度（像素）
    parameter CROSS_L     = 12         ,   // 十字臂长度（像素）

    //  ---- P3：团块跟踪 ----
    parameter MIN_AREA    = 400        ,   // 低于该面积不算目标
    //  ---- P4：时序跟踪 ----
    parameter TRK_EN      = 1'b0       ,   // 默认关（保持原有逐帧行为）
    parameter GATE        = 96         ,   // 门控半径（像素）
    parameter HIT_N       = 2          ,
    parameter LOST_N      = 6          ,
    //  ---- P5：自适应阈值 ----
    parameter ADAPT_EN    = 1'b0       ,
    parameter [7:0] ADAPT_PCT = 8'd15  ,   // 前景占比（%）
    //  ---- P6：自动曝光闭环 ----
    parameter AEC_EN      = 1'b0       ,
    parameter [7:0] AEC_EXP_DEF = 8'h08,
    //  ---- P7：中值预滤波 ----
    parameter MED_EN      = 1'b0       ,
    //  ---- P8：OSD ----
    parameter OSD_EN      = 1'b0       ,
    //  ---- P1：UART 上报 ----
    parameter UART_EN     = 1'b1       ,
    parameter UART_BAUD   = 115200     ,
    parameter TX_DIV      = 8
)(
    input                clk        ,   // 工作时钟（lcd_clk）
    input                rst_n      ,   // 复位
    input                vsync      ,   // 帧起始脉冲（rd_vsync）
    input                de         ,   // 数据有效（rdata_req）
    input      [15:0]    data_in    ,   // 输入像素（rddata）
    input      [3:0]     key        ,   // 按键（低电平有效）
    input                uart_rxd   ,   // UART 接收（参数写入）
    output               uart_txd   ,   // UART 发送（结果上报）
    output     [15:0]    data_out   ,   // 输出像素（到 LCD）
    output     [3:0]     led        ,   // LED 指示（低电平点亮）
    output     [5:0]     seg_sel    ,   // 数码管位选（低电平选通）
    output     [7:0]     seg_led    ,   // 数码管段码（低电平点亮）
    // 调试观察 / 上层测量台
    output               bond_valid ,   // 检测到目标
    output     [AW-1:0]  center_x   ,   // 灯圆心 x
    output     [AW-1:0]  center_y   ,   // 灯圆心 y
    output     [AW-1:0]  aim_x      ,   // 瞄准点 x（= 圆心 x）
    output     [AW-1:0]  aim_y          // 瞄准点 y（比圆心往上偏一点）
);

//localparam define
localparam SGUARD  = MORPH_N - 1;       // 形态学窗口的空间偏移
localparam Y_GUARD = 2*SGUARD;          // 帧首无效行数（行缓冲暖机）

//reg define
reg  [AW-1:0] x_cnt  ;   // 输入像素 x
reg  [AW-1:0] y_cnt  ;   // 输入像素 y（有效行从 1 起算）
reg           de_seen;   // 本帧是否已经出现过有效行
reg           de_d   ;   // de 延迟一拍，用来找帧尾
reg           de_v   ;   // 打一拍的 de
reg  [AW-1:0] x_v    ;   // 打一拍的 x
reg  [15:0]   data_v ;   // 打一拍的数据
reg           reg_written;   // UART 是否写过参数（写过就优先用寄存器值）

//wire define
wire [1:0]    sel      ;   // 当前选中的阈值项
wire [7:0]    th_g_kbd ;   // 键盘路的 TH_G
wire [7:0]    th_gr_kbd;   // 键盘路的 TH_G-R
wire [7:0]    th_gb_kbd;   // 键盘路的 TH_G-B
wire          disp_bin_k;  // 键盘路的显示模式
wire          disp_bin ;   // 实际显示模式
wire          seg_mask ;   // 颜色分割结果
wire          dil_mask ;   // 膨胀结果
wire          ero_mask ;   // 腐蚀结果（= 闭运算输出）
wire [15:0]   img_d    ;   // 延迟后的原图
wire          draw     ;   // 叠印标记
wire          mask_d   ;   // 排队暖机期间的二值图

wire [15:0]   pix_seg  ;   // 送去分割的像素（中值后或直通）
wire [15:0]   med_pix  ;   // 中值输出
wire          med_de   ;
wire [AW-1:0] med_x    ;

//  ---- P3 团块跟踪 ----
wire          raw_valid;
wire [AW-1:0] raw_l, raw_r, raw_t, raw_b;
wire [AW-1:0] raw_cx, raw_cy, raw_ax, raw_ay;
wire [31:0]   blob_area;
wire [2:0]    blob_cnt;
wire [AW-1:0] cent_x, cent_y;
wire [7:0]    fill_q8;

//  ---- P4 跟踪输出 ----
wire          trk_valid;
wire [AW-1:0] trk_cx, trk_cy, trk_ax, trk_ay;
wire [4:0]    trk_lost;

//  ---- P5 自适应阈值 ----
wire [7:0]    th_gr_auto, th_gb_auto;
wire          adapt_ok;

//  ---- P2 寄存器文件 ----
wire [7:0]    rf_th_g, rf_th_gr, rf_th_gb, rf_rel_sat, rf_min_size;
wire [7:0]    rf_aim_h, rf_ring_t, rf_ctrl, rf_gate, rf_pct;
wire          rf_wr_pulse;
wire [7:0]    rx_data;
wire          rx_done;

//  ---- P6 自动曝光 ----
wire          aec_req_exec;
wire [15:0]   aec_req_addr;
wire [7:0]    aec_req_data, aec_exp_cur;
wire [31:0]   aec_sat_cnt;

//  ---- P0 仪表盘 ----
wire [31:0]   st_frame_cyc, st_mask_cnt;
wire [15:0]   st_fps, st_frame_lines, st_hit_frames, st_miss_frames;
wire          st_frame_tick;

//  ---- P8 OSD ----
wire          osd_on;
wire [15:0]   osd_color;
wire [7:0]    osd_hraddr;
wire [19:0]   osd_hrdata;

//*****************************************************
//**                    main code
//*****************************************************

//-------------------------------------------------------
// 输入对齐：把 (data_in, de) 打一拍，后面都用打拍后的 de 和像素计数
//   x_v  : 一行内 0 ~ IMG_W-1
//   y_cnt : 有效行从 1 起算
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
        if(!de) x_cnt <= {AW{1'b0}};
        else    x_cnt <= x_cnt + 1'b1;

        de_v   <= de;
        data_v <= data_in;
        x_v    <= x_cnt;

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
// (1) 按键配置：把四按键映射到三个阈值 + 显示模式
//-------------------------------------------------------
vision_cfg #(
    .CLK_FREQ  (CLK_FREQ ),
    .TH_G_DEF  (TH_G_DEF ),
    .TH_GR_DEF (TH_GR_DEF),
    .TH_GB_DEF (TH_GB_DEF)
) u_vision_cfg (
    .clk      (clk        ),
    .rst_n    (rst_n      ),
    .key      (key        ),
    .sel      (sel        ),
    .th_g     (th_g_kbd   ),
    .th_gr    (th_gr_kbd  ),
    .th_gb    (th_gb_kbd  ),
    .disp_bin (disp_bin_k )
);

//-------------------------------------------------------
// (2) UART 参数写入：0xAA addr data (addr^data)
//-------------------------------------------------------
uart_rx #(
    .CLK_FREQ (CLK_FREQ ),
    .BAUD     (UART_BAUD)
) u_uart_rx (
    .clk      (clk      ),
    .rst_n    (rst_n    ),
    .rxd      (uart_rxd ),
    .rx_data  (rx_data  ),
    .rx_done  (rx_done  )
);

reg_file u_reg_file (
    .clk        (clk         ),
    .rst_n      (rst_n       ),
    .rx_done    (rx_done     ),
    .rx_data    (rx_data     ),
    .r_th_g     (rf_th_g     ),
    .r_th_gr    (rf_th_gr    ),
    .r_th_gb    (rf_th_gb    ),
    .r_rel_sat  (rf_rel_sat  ),
    .r_min_size (rf_min_size ),
    .r_aim_h    (rf_aim_h    ),
    .r_ring_t   (rf_ring_t   ),
    .r_ctrl     (rf_ctrl     ),
    .r_gate     (rf_gate     ),
    .r_pct      (rf_pct      ),
    .wr_pulse   (rf_wr_pulse )
);

//  写过一次参数之后，阈值以寄存器为准（没写过就完全沿用按键行为 -> 默认行为不变）
always @(posedge clk or negedge rst_n) begin
    if(!rst_n) reg_written <= 1'b0;
    else if(rf_wr_pulse) reg_written <= 1'b1;
end

//  各功能的实际开关：编译期参数 OR 运行时寄存器位
wire adapt_on = ADAPT_EN | rf_ctrl[0];
wire med_on   = MED_EN   | rf_ctrl[1];
wire aec_on   = AEC_EN   | rf_ctrl[2];
wire osd_on_e = OSD_EN   | rf_ctrl[4];

wire [7:0] th_g  = reg_written ? rf_th_g  : th_g_kbd;
wire [7:0] th_gr = adapt_on ? th_gr_auto : (reg_written ? rf_th_gr : th_gr_kbd);
wire [7:0] th_gb = adapt_on ? th_gb_auto : (reg_written ? rf_th_gb : th_gb_kbd);

assign disp_bin = disp_bin_k | rf_ctrl[3];

//-------------------------------------------------------
// (3) 中值预滤波（MED 关时纯直通，零延迟）
//-------------------------------------------------------
median3x3 #(
    .WIDTH (IMG_W),
    .AW    (AW   )
) u_median (
    .clk   (clk    ),
    .rst_n (rst_n  ),
    .de    (de_v   ),
    .x     (x_v    ),
    .din   (data_v ),
    .de_o  (med_de ),
    .x_o   (med_x  ),
    .dout  (med_pix)
);

assign pix_seg = med_on ? med_pix : data_v;

//-------------------------------------------------------
// (4) 自适应阈值：色度直方图
//-------------------------------------------------------
chroma_hist #(
    .PCT       (ADAPT_PCT),
    .MIN_TOTAL (2000     )
) u_chroma_hist (
    .clk       (clk        ),
    .rst_n     (rst_n      ),
    .vsync     (vsync      ),
    .de        (de_v       ),
    .r8        ({pix_seg[15:11], 3'b0}),
    .g8        ({pix_seg[10:5],  2'b0}),
    .b8        ({pix_seg[4:0],   3'b0}),
    .en        (adapt_on   ),
    .th_gr_man (reg_written ? rf_th_gr : th_gr_kbd),
    .th_gb_man (reg_written ? rf_th_gb : th_gb_kbd),
    .th_gr     (th_gr_auto ),
    .th_gb     (th_gb_auto ),
    .adapt_ok  (adapt_ok   ),
    .hraddr    (osd_hraddr ),
    .hrdata_gr (osd_hrdata ),
    .hrdata_gb ()
);

//-------------------------------------------------------
// (5) 颜色分割：绝对判据 + 相对饱和度闸（抗反光）
//-------------------------------------------------------
color_seg #(
    .REL_SAT_PCT (REL_SAT_PCT)
) u_color_seg (
    .rgb565 (pix_seg  ),
    .th_g   (th_g ),
    .th_gr  (th_gr),
    .th_gb  (th_gb),
    .mask   (seg_mask )
);

//-------------------------------------------------------
// (6) 形态学：膨胀 -> 腐蚀 = 闭运算
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

assign mask_d = ero_mask & (y_cnt > Y_GUARD);

//-------------------------------------------------------
// (7) 原图延迟：让原图与二值图空间对齐
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
// (8) 团块跟踪（P3）：行程级连通团块
//-------------------------------------------------------
//  UART 写 0x05 后，偏移取 {参数高 8 位, 寄存器低 8 位}。
//  372 = 16'h0174 -> 高 8 位 1、低 8 位 0x74(116)，reg_file 的复位值也是 116，
//  所以只写别的阈值寄存器不会把瞄准高度改掉。
wire [15:0] aim_h_eff = reg_written ? {AIM_H_Q8[15:8], rf_aim_h} : AIM_H_Q8;

blob_track #(
    .WIDTH    (IMG_W    ),
    .HEIGHT   (IMG_H    ),
    .AW       (AW       ),
    .MIN_AREA (MIN_AREA )
) u_blob_track (
    .clk        (clk        ),
    .rst_n      (rst_n      ),
    .vsync      (vsync      ),
    .de         (de_v       ),
    .x          (x_v        ),
    .y          (y_cnt      ),
    .mask       (mask_d     ),
    .aim_h_q8   (aim_h_eff   ),   // 运行时可变：UART 0x05 只覆盖低 8 位（小数）
    .bond_valid (raw_valid  ),
    .bond_l     (raw_l      ),
    .bond_r     (raw_r      ),
    .bond_t     (raw_t      ),
    .bond_b     (raw_b      ),
    .center_x   (raw_cx     ),
    .center_y   (raw_cy     ),
    .aim_x      (raw_ax     ),
    .aim_y      (raw_ay     ),
    .blob_area  (blob_area  ),
    .blob_cnt   (blob_cnt   ),
    .cent_x     (cent_x     ),
    .cent_y     (cent_y     ),
    .fill_q8    (fill_q8    )
);

//-------------------------------------------------------
// (9) 时序门控 + alpha-beta 跟踪（P4，默认关闭）
//     关闭时 bond_valid / center_* 直接取团块跟踪的逐帧结果
//-------------------------------------------------------
track_ab #(
    .AW     (AW    ),
    .WIDTH  (IMG_W ),
    .HEIGHT (IMG_H ),
    .GATE   (GATE  ),
    .HIT_N  (HIT_N ),
    .LOST_N (LOST_N)
) u_track_ab (
    .clk       (clk       ),
    .rst_n     (rst_n     ),
    .vsync     (vsync     ),
    .raw_valid (TRK_EN ? raw_valid : 1'b0),
    .raw_cx    (raw_cx    ),
    .raw_cy    (raw_cy    ),
    .raw_ay    (raw_ay    ),
    .valid     (trk_valid ),
    .cx        (trk_cx    ),
    .cy        (trk_cy    ),
    .ax        (trk_ax    ),
    .ay        (trk_ay    ),
    .lost_cnt  (trk_lost  )
);

//  默认（TRK_EN=0）走逐帧结果；打开后走滤波后的结果
reg          bond_valid_r;
reg  [AW-1:0] center_x_r, center_y_r, aim_x_r, aim_y_r;
reg  [AW-1:0] bl, br, bt, bb;
reg  [AW:0]   bond_w;

always @(posedge clk or negedge rst_n) begin
    if(!rst_n) begin
        bond_valid_r <= 1'b0;
        center_x_r <= {AW{1'b0}}; center_y_r <= {AW{1'b0}};
        aim_x_r    <= {AW{1'b0}}; aim_y_r    <= {AW{1'b0}};
        bl <= {AW{1'b0}}; br <= {AW{1'b0}};
        bt <= {AW{1'b0}}; bb <= {AW{1'b0}};
        bond_w <= {(AW+1){1'b0}};
    end
    else begin
        bond_valid_r <= TRK_EN ? trk_valid : raw_valid;
        center_x_r   <= TRK_EN ? trk_cx    : raw_cx;
        center_y_r   <= TRK_EN ? trk_cy    : raw_cy;
        aim_x_r      <= TRK_EN ? trk_ax    : raw_ax;
        aim_y_r      <= TRK_EN ? trk_ay    : raw_ay;
        bl <= raw_l;
        br <= raw_r;
        bt <= raw_t;
        bb <= raw_b;
        bond_w <= {1'b0, raw_r} - {1'b0, raw_l} + 1'b1;
    end
end

assign bond_valid = bond_valid_r;
assign center_x   = center_x_r;
assign center_y   = center_y_r;
assign aim_x      = aim_x_r;
assign aim_y      = aim_y_r;

//-------------------------------------------------------
// (10) 叠印：红色圆环（套住灯）+ 瞄准点十字
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
// (11) OSD（P8）：数值 + 直方图条形图
//-------------------------------------------------------
osd_text #(
    .SCALE (2'd1)
) u_osd (
    .clk       (clk        ),
    .rst_n     (rst_n      ),
    .vsync     (vsync      ),
    .x         (x_v        ),
    .y         (y_cnt      ),
    .en        (osd_on_e   ),
    .fps       (st_fps     ),
    .th_gr     (th_gr  ),
    .area      (blob_area  ),
    .fill_in   (fill_q8    ),
    .hraddr    (osd_hraddr ),
    .hrdata_gr (osd_hrdata ),
    .osd_on    (osd_on     ),
    .osd_color (osd_color  )
);

//-------------------------------------------------------
// (12) 显示合成
//   模式 0：原图变暗 + 命中处显示原色 + 红色标记
//   模式 1：纯二值图（白 = 命中）
//   OSD 画在最上层
//-------------------------------------------------------
wire [15:0] dim_pix = {1'b0, img_d[15:12],
                       1'b0, img_d[10:6],
                       1'b0, img_d[4:1]};

wire [15:0] disp_pix = disp_bin ? (mask_d ? 16'hFFFF : 16'h0000)
                                : (mask_d ? img_d  : dim_pix);

assign data_out = draw ? 16'hF800 : (osd_on ? osd_color : disp_pix);

//-------------------------------------------------------
// (13) 自动曝光闭环（P6，默认关闭）
//      关掉时它不产生任何 I2C 请求，相机行为与改动前一致
//-------------------------------------------------------
aec_loop #(
    .EXP_DEF (AEC_EXP_DEF)
) u_aec_loop (
    .clk       (clk          ),
    .rst_n     (rst_n        ),
    .vsync     (vsync        ),
    .de        (de_v         ),
    .r8        ({pix_seg[15:11], 3'b0}),
    .g8        ({pix_seg[10:5],  2'b0}),
    .b8        ({pix_seg[4:0],   3'b0}),
    .en        (aec_on       ),
    .init_done (1'b1         ),
    .req_exec  (aec_req_exec ),
    .req_addr  (aec_req_addr ),
    .req_data  (aec_req_data ),
    .req_done  (1'b1         ),
    .exp_cur   (aec_exp_cur  ),
    .sat_cnt   (aec_sat_cnt  )
);

//-------------------------------------------------------
// (14) 结果上报（P1）：UART 定长帧
//-------------------------------------------------------
result_frame #(
    .CLK_FREQ (CLK_FREQ ),
    .BAUD     (UART_BAUD),
    .TX_DIV   (TX_DIV   )
) u_result_frame (
    .clk        (clk        ),
    .rst_n      (rst_n      ),
    .frame_tick (st_frame_tick),
    .valid      (bond_valid ),
    .cx         (center_x   ),
    .cy         (center_y   ),
    .ax         (aim_x      ),
    .ay         (aim_y      ),
    .bw         (bond_w     ),
    .area       (blob_area  ),
    .fill_q8    (fill_q8    ),
    .blob_cnt   (blob_cnt   ),
    .adapt_ok   (adapt_ok   ),
    .disp_bin   (disp_bin   ),
    .txd        (uart_txd   )
);

//-------------------------------------------------------
// (15) 仪表盘（P0）：帧率 / 帧长 / 掩码像素数 / 命中率
//      纯观测，不参与判决。mark_debug 已打在输出上：
//      Vivado -> Open Synthesized Design -> Set Up Debug 会自动认出来。
//-------------------------------------------------------
vision_stat #(
    .CLK_FREQ (CLK_FREQ)
) u_vision_stat (
    .clk         (clk           ),
    .rst_n       (rst_n         ),
    .vsync       (vsync         ),
    .de          (de_v          ),
    .mask        (mask_d        ),
    .bond_valid  (bond_valid    ),
    .frame_cyc   (st_frame_cyc  ),
    .fps         (st_fps        ),
    .frame_lines (st_frame_lines),
    .mask_cnt    (st_mask_cnt   ),
    .hit_frames  (st_hit_frames ),
    .miss_frames (st_miss_frames),
    .frame_tick  (st_frame_tick )
);

//-------------------------------------------------------
// (16) 6 位数码管：显示三个阈值 / 目标尺寸
//-------------------------------------------------------
seg_display #(
    .CLK_FREQ (CLK_FREQ)
) u_seg_display (
    .clk        (clk        ),
    .rst_n      (rst_n      ),
    .sel        (sel        ),
    .th_g       (th_g   ),
    .th_gr      (th_gr  ),
    .th_gb      (th_gb  ),
    .bond_valid (bond_valid ),
    .bond_w     (bond_w     ),
    .disp_bin   (disp_bin   ),
    .seg_sel    (seg_sel    ),
    .seg_led    (seg_led    )
);

//-------------------------------------------------------
// (17) LED 指示
//   led[0] : 当前在调 TH_G
//   led[1] : 当前在调 TH_G-R
//   led[2] : 当前在调 TH_G-B
//   led[3] : 检测到目标常亮（未检测到时 1.5Hz 闪烁，顺便当心跳）
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
