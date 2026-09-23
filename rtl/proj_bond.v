//****************************************Copyright (c)***********************************//
// File name:           proj_bond
// Descriptions:        双投影找最大绿色块（圆）+ 边界框 / 圆心
//
//   靶标是【单个大绿色圆灯】，所以不需要原方案的「两根灯条 + 配对」，
//   改用【X / Y 两个 1D 投影】直接把那个圆框住：
//
//     1. 整帧累加两个直方图
//          hist_x[x] = 第 x 列被判定为绿色的像素个数
//          hist_y[y] = 第 y 行被判定为绿色的像素个数
//     2. 帧末（垂直消隐期）先扫 hist_x：取【最宽】的一段连续亮列 run
//        -> 左右边界 bl / br；再扫 hist_y：取【最长】的一段连续亮行 run
//        -> 上下边界 bt / bb
//     3. 校验（圆形状先验，防止反光/杂色块被当成靶标）：
//          - 宽、高都 >= MIN_SIZE
//          - 宽高比在 2:1 以内（圆，或略微压扁的椭圆）
//          - 最亮那一列的峰值 >= 3/4 * 高（圆的正中列弦长 = 直径）
//     4. 输出边界框 + 中心（半径见 overlay_box.v：(宽+高)/4）
//
//   和旧版的差别：
//     - 旧版要「两根灯条配对」；新版只有一个目标，直接取最宽 / 最长 run
//     - X 与 Y 在【同一帧】算完，所以框不再慢一帧
//     - 阈值 TH_MIN 是参数，不写死
//
//   两个直方图都用 line_buffer.v 那套【分散式 RAM 标准模板】
//   （同步写 + assign dout = mem[raddr] 连续赋值读），Vivado 才能稳定推断 LUTRAM。
//   单一写端口（扫描时清零 / 累加时 +1 用 mux 合成 we/addr/data），
//   多写分支会挡掉 RAM 推断。
//
//   时序：扫 X 用 WIDTH+1 = 801 拍，扫 Y 用 HEIGHT+1 = 481 拍，共约 1283 拍，
//         垂直消隐有约 47000 拍（1056 * 45），时间非常宽裕。
//----------------------------------------------------------------------------------------
//****************************************************************************************//

`timescale 1ns / 1ps

module proj_bond #(
    parameter WIDTH    = 800 ,   // 图像宽（hist_x 深度）
    parameter HEIGHT   = 480 ,   // 图像高（hist_y 深度）
    parameter AW       = 10  ,   // 坐标位宽
    parameter HW       = 10  ,   // 直方图位宽（>= log2(HEIGHT)）
    parameter Y_GUARD  = 16  ,   // 顶部形态学暖机行（这些行不参与投影）
    parameter TH_MIN   = 24  ,   // 直方图阈值：一列 / 一行的最少亮点数
    parameter MIN_SIZE = 24      // 目标最小边长（宽和高都要 >= 它）
)(
    input                clk       ,   // 时钟
    input                rst_n     ,   // 复位
    input                vsync     ,   // 帧开始脉冲（1 拍）
    input                de        ,   // 行数据有效
    input      [AW-1:0]  x         ,   // 当前像素 x
    input      [AW-1:0]  y         ,   // 当前像素 y（有效行从 1 起算）
    input                mask      ,   // 绿色二值图
    // 输出：屏幕坐标，给 overlay_box 用
    output reg           bond_valid,   // 边界框有效
    output reg [AW-1:0]  bond_l    ,
    output reg [AW-1:0]  bond_r    ,
    output reg [AW-1:0]  bond_t    ,
    output reg [AW-1:0]  bond_b    ,
    output reg [AW-1:0]  center_x  ,
    output reg [AW-1:0]  center_y
);

//localparam define
localparam S_IDLE  = 2'd0;
localparam S_SCANX = 2'd1;
localparam S_SCANY = 2'd2;
localparam S_LATCH = 2'd3;

//reg define
(* ram_style = "distributed" *) reg [HW-1:0] hist_x [0:WIDTH-1] ;   // 列投影
(* ram_style = "distributed" *) reg [HW-1:0] hist_y [0:HEIGHT-1];   // 行投影

reg  [1:0]    state    ;        // 主状态
reg  [AW:0]   scan_cnt ;        // 扫描计数器

// X 扫描
reg  [AW-1:0] x_st     ;        // 当前 run 起始列
reg  [AW-1:0] x_last   ;        // 当前 run 最后亮列
reg           x_run    ;        // 是否正在一个 run 内
reg  [HW-1:0] x_peak   ;        // 当前 run 内的峰列高度
reg  [AW:0]   xw_best  ;        // 最宽 run 的宽度
reg  [AW-1:0] xs_best  ;        // 最宽 run 的起始列
reg  [HW-1:0] xp_best  ;        // 最宽 run 的峰列高度

// Y 扫描
reg  [AW-1:0] y_st     ;
reg  [AW-1:0] y_last   ;
reg           y_run    ;
reg  [AW:0]   yh_best  ;        // 最长 run 的长度
reg  [AW-1:0] ys_best  ;        // 最长 run 的起始行

//wire define
wire scan_x = (state == S_SCANX);
wire scan_y = (state == S_SCANY);

wire [AW-1:0] rx_addr = scan_x ? scan_cnt[AW-1:0] : x;
wire [AW-1:0] ry_addr = scan_y ? scan_cnt[AW-1:0] : y;
wire [HW-1:0] hx      = hist_x[rx_addr];      // 组合读（分散式 RAM 模板）
wire [HW-1:0] hy      = hist_y[ry_addr];

// 累加条件：只在 S_IDLE、有效像素、且不在顶部暖机区
wire accum = (state == S_IDLE) && de && mask &&
             (y > Y_GUARD) && (x < WIDTH) && (y < HEIGHT);

// 单写端口：扫描时清零、累加时 +1
wire           wx_we   = scan_x ? (scan_cnt < WIDTH)  : accum;
wire [AW-1:0]  wx_addr = scan_x ? scan_cnt[AW-1:0]    : x;
wire [HW-1:0]  wx_data = scan_x ? {HW{1'b0}}          : (hx + 1'b1);

wire           wy_we   = scan_y ? (scan_cnt < HEIGHT) : accum;
wire [AW-1:0]  wy_addr = scan_y ? scan_cnt[AW-1:0]    : y;
wire [HW-1:0]  wy_data = scan_y ? {HW{1'b0}}          : (hy + 1'b1);

// 扫描时的「亮」（scan_cnt 越界时强制为 0，用来给最后一个 run 收尾）
wire lit_x = scan_x && (scan_cnt < WIDTH)  && (hx >= TH_MIN);
wire lit_y = scan_y && (scan_cnt < HEIGHT) && (hy >= TH_MIN);

// 当前 run 的长度
wire [AW:0] xw = {1'b0,x_last} - {1'b0,x_st} + 1'b1;
wire [AW:0] yh = {1'b0,y_last} - {1'b0,y_st} + 1'b1;

// 几何校验用的倍数（显式定位宽，避免表达式被截断）
wire [AW+1:0] xp4 = {xp_best , 2'b00}          ;   // 峰列高度 * 4
wire [AW+1:0] yh3 = yh_best + {yh_best,1'b0}   ;   // 高度 * 3
wire [AW+1:0] xw2 = {xw_best , 1'b0}           ;   // 宽度 * 2
wire [AW+1:0] yh2 = {yh_best , 1'b0}           ;   // 高度 * 2

// 圆形先验校验：够大 + 宽高比在 2:1 内 + 峰列高度 >= 3/4 高
wire ok = (xw_best >= MIN_SIZE) && (yh_best >= MIN_SIZE) &&
          (xw_best <= yh2)      && (yh_best <= xw2)      &&
          (xp4     >= yh3);

//*****************************************************
//**                    main code
//*****************************************************

//-------------------------------------------------------
// 直方图（单一写端口）
//-------------------------------------------------------
always @(posedge clk) begin
    if(wx_we)
        hist_x[wx_addr] <= wx_data;
end

always @(posedge clk) begin
    if(wy_we)
        hist_y[wy_addr] <= wy_data;
end

//-------------------------------------------------------
// 主状态机：累加 -> 扫 X -> 扫 Y -> 出结果
//-------------------------------------------------------
always @(posedge clk or negedge rst_n) begin
    if(!rst_n) begin
        state      <= S_IDLE;
        scan_cnt   <= {(AW+1){1'b0}};
        x_st       <= {AW{1'b0}};
        x_last     <= {AW{1'b0}};
        x_run      <= 1'b0;
        x_peak     <= {HW{1'b0}};
        xw_best    <= {(AW+1){1'b0}};
        xs_best    <= {AW{1'b0}};
        xp_best    <= {HW{1'b0}};
        y_st       <= {AW{1'b0}};
        y_last     <= {AW{1'b0}};
        y_run      <= 1'b0;
        yh_best    <= {(AW+1){1'b0}};
        ys_best    <= {AW{1'b0}};
        bond_valid <= 1'b0;
        bond_l     <= {AW{1'b0}};
        bond_r     <= {AW{1'b0}};
        bond_t     <= {AW{1'b0}};
        bond_b     <= {AW{1'b0}};
        center_x   <= {AW{1'b0}};
        center_y   <= {AW{1'b0}};
    end
    else case(state)
    //-----------------------------------------------
    // 帧内：累加两个直方图
    //-----------------------------------------------
    S_IDLE: begin
        if(vsync) begin
            state    <= S_SCANX;
            scan_cnt <= {(AW+1){1'b0}};
            x_run    <= 1'b0;
            y_run    <= 1'b0;
            xw_best  <= {(AW+1){1'b0}};
            yh_best  <= {(AW+1){1'b0}};
            xp_best  <= {HW{1'b0}};
        end
    end
    //-----------------------------------------------
    // 扫 hist_x：找最宽的亮列 run
    //-----------------------------------------------
    S_SCANX: begin
        if(lit_x) begin
            if(!x_run) begin
                x_run  <= 1'b1;
                x_st   <= scan_cnt[AW-1:0];
                x_peak <= hx;                 // 新 run：峰值从这一列开始
            end
            else if(hx > x_peak)
                x_peak <= hx;
            x_last <= scan_cnt[AW-1:0];
        end
        else if(x_run) begin                  // run 结束，结算宽度
            x_run <= 1'b0;
            if(xw > xw_best) begin
                xw_best <= xw;
                xs_best <= x_st;
                xp_best <= x_peak;
            end
        end

        scan_cnt <= scan_cnt + 1'b1;
        if(scan_cnt >= WIDTH) begin
            state    <= S_SCANY;
            scan_cnt <= {(AW+1){1'b0}};
        end
    end
    //-----------------------------------------------
    // 扫 hist_y：找最长的亮行 run
    //-----------------------------------------------
    S_SCANY: begin
        if(lit_y) begin
            if(!y_run) begin
                y_run <= 1'b1;
                y_st  <= scan_cnt[AW-1:0];
            end
            y_last <= scan_cnt[AW-1:0];
        end
        else if(y_run) begin
            y_run <= 1'b0;
            if(yh > yh_best) begin
                yh_best <= yh;
                ys_best <= y_st;
            end
        end

        scan_cnt <= scan_cnt + 1'b1;
        if(scan_cnt >= HEIGHT) begin
            state    <= S_LATCH;
            scan_cnt <= {(AW+1){1'b0}};
        end
    end
    //-----------------------------------------------
    // 出结果（含圆形先验校验）
    //-----------------------------------------------
    S_LATCH: begin
        bond_l   <= ok ? xs_best                        : {AW{1'b0}};
        bond_r   <= ok ? (xs_best + xw_best - 1'b1)     : {AW{1'b0}};
        bond_t   <= ok ? ys_best                        : {AW{1'b0}};
        bond_b   <= ok ? (ys_best + yh_best - 1'b1)     : {AW{1'b0}};
        center_x <= ok ? ((xs_best + (xs_best + xw_best) - 1'b1) >> 1) : {AW{1'b0}};
        center_y <= ok ? ((ys_best + (ys_best + yh_best) - 1'b1) >> 1) : {AW{1'b0}};
        bond_valid <= ok;
        state <= S_IDLE;
    end
    //-----------------------------------------------
    default: state <= S_IDLE;
    endcase
end

endmodule
