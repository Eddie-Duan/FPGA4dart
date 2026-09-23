//****************************************Copyright (c)***********************************//
// File name:           proj_bond
// Descriptions:        双投影找最大绿色块（圆）+ 边界框 / 圆心 / 瞄准点
//
//   靶标是【单个大绿色圆灯】，用 X / Y 两个 1D 直方图把它框住：
//     ① 整帧累加
//          hist_x[x] = 第 x 列被判定为绿色的像素个数
//          hist_y[y] = 第 y 行被判定为绿色的像素个数
//     ② 帧末（垂直消隐期）扫 hist_x：取【第一个 / 最后一个】>= TH_MIN 的列
//        -> 左右边界 bl / br；再扫 hist_y 同理 -> 上下边界 bt / bb
//     ③ 形状校验（圆形先验，挡掉反光块 / 杂色块 / 两个分开的绿块）：
//          - 宽、高都 >= MIN_SIZE
//          - 宽高比在 2:1 以内
//          - 最亮那一列的高度 >= 高度的 1/2
//     ④ 输出边界框、圆心，以及【瞄准点】（圆心往上偏移一点，见 AIM_H_Q8）
//
//   ★ 为什么用「区间外沿」而不是「最长的连续 run」★
//       反光（LCD 镜面反射的白光）会在灯上打出一个横贯的洞。旧版取「hist 连续 >= 门槛
//       的最长区间」，洞上方的亮像素和下方的亮像素会被切成两段，取到的那段高度只有
//       原来的一半 —— 框变小、圆心整体上移，看起来就是「识别不到了」。
//       实测（tools/model_morph.py）：
//         眩光带高 10px -> 旧版 h=94（真的是 199）、圆心 y 从 248 跳到 195；新版不受影响
//         眩光带高 60px -> 旧版 h=69；新版仍然是 199
//       取「第一个/最后一个 >= TH_MIN 的位置」只关心外沿，中间的洞不影响结果；
//       代价是对「两个分开的绿块」更敏感，所以形状校验里的宽高比 + 峰值高度必须留着。
//
//   两个直方图都用 line_buffer.v 那套【分散式 RAM 标准模板】
//   （同步写 + assign dout = mem[raddr] 连续赋值读），Vivado 才能稳定推断 LUTRAM；
//   单一写端口（扫描时清零 / 累加时 +1 用 mux 合成 we/addr/data），多写分支会挡掉推断。
//
//   时序：扫 X 用 WIDTH 拍、扫 Y 用 HEIGHT 拍，共 1280 拍；
//         垂直消隐有约 47000 拍（1056 x 45），时间非常宽裕。
//----------------------------------------------------------------------------------------
//****************************************************************************************//

`timescale 1ns / 1ps

module proj_bond #(
    parameter WIDTH    = 800   ,   // 图像宽（hist_x 深度）
    parameter HEIGHT   = 480   ,   // 图像高（hist_y 深度）
    parameter AW       = 10    ,   // 坐标位宽
    parameter HW       = 10    ,   // 直方图位宽（>= log2(HEIGHT)）
    parameter Y_GUARD  = 16    ,   // 顶部形态学暖机行（这些行不参与投影）
    parameter TH_MIN   = 4     ,   // 一列 / 一行的最少亮点数
    parameter MIN_SIZE = 24    ,   // 目标最小边长（宽和高都要 >= 它）
    parameter [7:0] AIM_H_Q8 = 8'd64   // 瞄准点在灯心上方 = 宽度 x AIM_H_Q8/256
)(
    input                clk       ,   // 时钟
    input                rst_n     ,   // 复位
    input                vsync     ,   // 帧开始脉冲（1 拍）
    input                de        ,   // 行数据有效
    input      [AW-1:0]  x         ,   // 当前像素 x
    input      [AW-1:0]  y         ,   // 当前像素 y（有效行从 1 起算）
    input                mask      ,   // 绿色二值图
    // 输出：屏幕坐标，给 overlay_box / 云台用
    output reg           bond_valid,   // 边界框有效
    output reg [AW-1:0]  bond_l    ,   // 左
    output reg [AW-1:0]  bond_r    ,   // 右
    output reg [AW-1:0]  bond_t    ,   // 上
    output reg [AW-1:0]  bond_b    ,   // 下
    output reg [AW-1:0]  center_x  ,   // 圆心 x
    output reg [AW-1:0]  center_y  ,   // 圆心 y
    output reg [AW-1:0]  aim_x     ,   // 瞄准点 x（= 圆心 x）
    output reg [AW-1:0]  aim_y         // 瞄准点 y（圆心往上偏一点）
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
reg           x_seen   ;        // 有没有见过 >= TH_MIN 的列
reg  [AW-1:0] xs_best  ;        // 最左的亮列
reg  [AW-1:0] xe_best  ;        // 最右的亮列
reg           y_seen   ;        // 有没有见过 >= TH_MIN 的行
reg  [AW-1:0] ys_best  ;        // 最上的亮行
reg  [AW-1:0] ye_best  ;        // 最下的亮行
reg  [HW-1:0] xp_best  ;        // 全帧最高的一列（列弦长峰值）

//wire define
wire scan_x = (state == S_SCANX);
wire scan_y = (state == S_SCANY);

wire [AW-1:0] rx_addr = scan_x ? scan_cnt[AW-1:0] : x;
wire [AW-1:0] ry_addr = scan_y ? scan_cnt[AW-1:0] : ((y < HEIGHT) ? y : {AW{1'b0}});
wire [HW-1:0] hx      = hist_x[rx_addr];      // 组合读（分散式 RAM 模板）
wire [HW-1:0] hy      = hist_y[ry_addr];

// 累加条件：只在 S_IDLE、有效像素、且不在顶部暖机区
wire accum = (state == S_IDLE) && de && mask &&
             (y > Y_GUARD) && (x < WIDTH) && (y < HEIGHT);

// 单写端口：扫描时清零、累加时 +1
wire           wx_we   = scan_x ? 1'b1              : accum;
wire [AW-1:0]  wx_addr = scan_x ? scan_cnt[AW-1:0]  : x;
wire [HW-1:0]  wx_data = scan_x ? {HW{1'b0}}        : (hx + 1'b1);

wire           wy_we   = scan_y ? 1'b1              : accum;
wire [AW-1:0]  wy_addr = scan_y ? scan_cnt[AW-1:0]  : y;
wire [HW-1:0]  wy_data = scan_y ? {HW{1'b0}}        : (hy + 1'b1);

// 扫描时的「这一列/行算数」
wire lit_x = scan_x && (hx >= TH_MIN);
wire lit_y = scan_y && (hy >= TH_MIN);

//-------------------------------------------------------
// 由外沿算尺寸 / 形状校验 / 瞄准点（S_LATCH 用，都是组合的）
//-------------------------------------------------------
wire [AW:0]   bw  = {1'b0,xe_best} - {1'b0,xs_best} + 1'b1;   // 宽
wire [AW:0]   bh  = {1'b0,ye_best} - {1'b0,ys_best} + 1'b1;   // 高
wire [AW+1:0] bw2 = {bw,1'b0};                                 // 宽 x2
wire [AW+1:0] bh2 = {bh,1'b0};                                 // 高 x2
wire [AW:0]   xp2 = {1'b0,xp_best} << 1;                       // 峰值 x2

// 圆形先验：够大 + 不太扁 + 峰值高度 >= 高的一半
// （最后一条用来挡「上下/斜对两块分开的绿块」被外沿串成一个框）
wire ok = x_seen && y_seen &&
          (bw >= MIN_SIZE) && (bh >= MIN_SIZE) &&
          (bw <= bh2)      && (bh <= bw2)      &&
          (xp2 >= bh);

wire [AW:0] cx_t = ({1'b0,xs_best} + {1'b0,xe_best}) >> 1;     // 圆心 x
wire [AW:0] cy_t = ({1'b0,ys_best} + {1'b0,ye_best}) >> 1;     // 圆心 y

// 注意：Verilog 里 a*b 的结果位宽 = max(两个操作数位宽)，不是两者之和。
// 直接写 (bw * AIM_H_Q8) >> 8 会被算在 11bit 上：199*64=12736 截成 448 -> 只抬升 1 像素。
wire [AW+7:0] up_full = bw * AIM_H_Q8;        // 19bit，够 800*255
wire [AW:0]   up_t    = up_full >> 8;         // 瞄准点抬升量（AIM_H_Q8/256 x 宽度）
wire [AW:0] ay_t = (cy_t > up_t) ? (cy_t - up_t) : {(AW+1){1'b0}};

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
//   扫描计数器用 [0, WIDTH-1] / [0, HEIGHT-1] 闭区间，
//   最后一个元素在「切状态的那一拍」处理，顺带避免越界读 RAM
//-------------------------------------------------------
always @(posedge clk or negedge rst_n) begin
    if(!rst_n) begin
        state      <= S_IDLE;
        scan_cnt   <= {(AW+1){1'b0}};
        x_seen     <= 1'b0;
        xs_best    <= {AW{1'b0}};
        xe_best    <= {AW{1'b0}};
        y_seen     <= 1'b0;
        ys_best    <= {AW{1'b0}};
        ye_best    <= {AW{1'b0}};
        xp_best    <= {HW{1'b0}};
        bond_valid <= 1'b0;
        bond_l     <= {AW{1'b0}};
        bond_r     <= {AW{1'b0}};
        bond_t     <= {AW{1'b0}};
        bond_b     <= {AW{1'b0}};
        center_x   <= {AW{1'b0}};
        center_y   <= {AW{1'b0}};
        aim_x      <= {AW{1'b0}};
        aim_y      <= {AW{1'b0}};
    end
    else case(state)
    //-----------------------------------------------
    // 帧内：累加两个直方图
    //-----------------------------------------------
    S_IDLE: begin
        if(vsync) begin
            state    <= S_SCANX;
            scan_cnt <= {(AW+1){1'b0}};
            x_seen   <= 1'b0;
            y_seen   <= 1'b0;
            xp_best  <= {HW{1'b0}};
        end
    end
    //-----------------------------------------------
    // 扫 hist_x：取最左 / 最右的亮列
    //-----------------------------------------------
    S_SCANX: begin
        if(lit_x) begin
            if(!x_seen) begin
                x_seen  <= 1'b1;
                xs_best <= scan_cnt[AW-1:0];
            end
            xe_best <= scan_cnt[AW-1:0];
        end
        if(hx > xp_best)
            xp_best <= hx;

        if(scan_cnt >= (WIDTH - 1)) begin
            state    <= S_SCANY;
            scan_cnt <= {(AW+1){1'b0}};
        end
        else
            scan_cnt <= scan_cnt + 1'b1;
    end
    //-----------------------------------------------
    // 扫 hist_y：取最上 / 最下的亮行
    //-----------------------------------------------
    S_SCANY: begin
        if(lit_y) begin
            if(!y_seen) begin
                y_seen  <= 1'b1;
                ys_best <= scan_cnt[AW-1:0];
            end
            ye_best <= scan_cnt[AW-1:0];
        end

        if(scan_cnt >= (HEIGHT - 1)) begin
            state    <= S_LATCH;
            scan_cnt <= {(AW+1){1'b0}};
        end
        else
            scan_cnt <= scan_cnt + 1'b1;
    end
    //-----------------------------------------------
    // 出结果（含圆形先验 + 瞄准点）
    //-----------------------------------------------
    S_LATCH: begin
        bond_l     <= ok ? xs_best   : {AW{1'b0}};
        bond_r     <= ok ? xe_best   : {AW{1'b0}};
        bond_t     <= ok ? ys_best   : {AW{1'b0}};
        bond_b     <= ok ? ye_best   : {AW{1'b0}};
        center_x   <= ok ? cx_t[AW-1:0] : {AW{1'b0}};
        center_y   <= ok ? cy_t[AW-1:0] : {AW{1'b0}};
        aim_x      <= ok ? cx_t[AW-1:0] : {AW{1'b0}};
        aim_y      <= ok ? ay_t[AW-1:0] : {AW{1'b0}};
        bond_valid <= ok;
        state      <= S_IDLE;
    end
    //-----------------------------------------------
    default: state <= S_IDLE;
    endcase
end

endmodule
