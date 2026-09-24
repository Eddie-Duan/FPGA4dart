`timescale 1ns / 1ps
//****************************************************************************************//
// File name:           chroma_hist
// Descriptions:        色度直方图 + 自适应阈值（P5）
//
//   为什么需要：
//     原来三个阈值全靠按键手调，换个距离 / 换个光照就得重调 —— 这正是「换个环境就
//     失效」的根本原因。这里每帧统计 G-R 与 G-B 的 256 bin 直方图，帧末取分位数
//     当阈值，让阈值自动跟着画面走。
//     **dart 的 PL 没有这个**：它的三阈值是 AXI 寄存器，由 PS 上的程序写死。
//
//   取阈值的规则：
//     让「色度 >= 阈值」的像素大约占整幅的 PCT%（默认 15%）。
//     从 bin 255 往下扫，累计到 >= total*PCT/100 的那个 bin 就是阈值。
//
//   保护：
//     - total < MIN_TOTAL（几乎是黑屏/全彩噪）时不更新，保持上一次的自动值
//     - ADAPT 关掉时直接透传手动阈值，行为与改动前完全一致
//     - 直方图在帧末扫描时顺手清零（256 拍），不占额外周期
//
//   【重要 / 曾经踩过的坑】整个模块的直方图必须只有**一个写端口**。
//     第一版把「统计时的 +1」和「扫描时的清零」写在两个 always 块里，
//     于是 hgr/hgb/total 都成了多驱动网络：xsim 容忍（自己挑一个驱动），
//     Vivado 直接报
//         [Synth 8-6859] multi-driven net on pin .../hgb[255][19]
//         [DRC MDRV-1] Multiple Driver Nets: Net .../Q[0] has multiple drivers
//     -> Opt_design 根本跑不起来。
//     现在用 we/addr/wdata 三个 wire 做 mux，合成**单个**写端口（也是 LUTRAM 推断的标准模板）。
//
//   资源：2 x (256 x 20bit) 分布式 RAM，约 160 LUT + 一个常量乘法器，0 BRAM。
//****************************************************************************************//
module chroma_hist #(
    parameter [7:0] PCT       = 8'd15  ,   // 前景占比（%），阈值取在 (100-PCT) 分位
    parameter       MIN_TOTAL = 2000       // 有效像素下限
)(
    input              clk        ,
    input              rst_n      ,
    input              vsync      ,
    input              de         ,
    input      [7:0]   r8         ,
    input      [7:0]   g8         ,
    input      [7:0]   b8         ,

    input              en         ,   // ADAPT_EN：0 = 透传手动阈值
    input      [7:0]   th_gr_man  ,
    input      [7:0]   th_gb_man  ,

    output reg [7:0]   th_gr      ,   // 最终使用阈值
    output reg [7:0]   th_gb      ,
    output reg         adapt_ok   ,   // 当前自动阈值是否有效

    //  OSD 直方图读口（异步读，给 P8 画条形图）
    input      [7:0]   hraddr     ,
    output     [19:0]  hrdata_gr  ,
    output     [19:0]  hrdata_gb
);

//localparam
localparam SC_IDLE = 2'd0, SC_RUN = 2'd1, SC_END = 2'd2;

//reg define
(* ram_style = "distributed" *) reg [19:0] hgr [0:255];
(* ram_style = "distributed" *) reg [19:0] hgb [0:255];

reg  [19:0] total    ;
reg  [1:0]  sc_state ;
reg  [8:0]  sc_i     ;
reg  [19:0] cum_gr   ;
reg  [19:0] cum_gb   ;
reg         hit_gr   ;
reg         hit_gb   ;
reg  [7:0]  thv_gr   ;
reg  [7:0]  thv_gb   ;
reg  [19:0] thr_cnt  ;
reg         vsync_d  ;

//wire define
wire vsync_rise = vsync & ~vsync_d;
wire scanning   = (sc_state != SC_IDLE);
wire [7:0] chr  = (g8 > r8) ? (g8 - r8) : 8'd0;
wire [7:0] chb  = (g8 > b8) ? (g8 - b8) : 8'd0;

//*****************************************************
//**                    main code
//*****************************************************

//-------------------------------------------------------
// 直方图的**唯一写端口**
//   扫描期间：地址 = sc_i，写 0（顺手清零）
//   统计期间：地址 = 色度，写 旧值+1（饱和）
//-------------------------------------------------------
wire [7:0]  h_addr   = scanning ? sc_i[7:0] : chr;
wire [7:0]  h_addr_b = scanning ? sc_i[7:0] : chb;
wire        hist_we  = scanning | (de & ~scanning);

wire [19:0] hgr_rd = hgr[h_addr];
wire [19:0] hgb_rd = hgb[h_addr_b];

wire [19:0] hgr_nx = scanning ? 20'd0
                   : ((hgr_rd == 20'hFFFFF) ? hgr_rd : (hgr_rd + 20'd1));
wire [19:0] hgb_nx = scanning ? 20'd0
                   : ((hgb_rd == 20'hFFFFF) ? hgb_rd : (hgb_rd + 20'd1));

always @(posedge clk) begin
    if(hist_we) begin
        hgr[h_addr]   <= hgr_nx;
        hgb[h_addr_b] <= hgb_nx;
    end
end

//  给 OSD 的异步读口
assign hrdata_gr = hgr[hraddr];
assign hrdata_gb = hgb[hraddr];

//-------------------------------------------------------
// vsync 上升沿 / 扫描状态机
//   注意：total 与 th_gr/th_gb/adapt_ok **只在这一个 always 块里赋值**（单驱动）
//-------------------------------------------------------
always @(posedge clk or negedge rst_n) begin
    if(!rst_n) begin
        vsync_d  <= 1'b0;
        total    <= 20'd0;
        sc_state <= SC_IDLE;
        sc_i     <= 9'd255;
        cum_gr   <= 20'd0;
        cum_gb   <= 20'd0;
        hit_gr   <= 1'b0;
        hit_gb   <= 1'b0;
        thv_gr   <= 8'd0;
        thv_gb   <= 8'd0;
        thr_cnt  <= 20'd0;
        th_gr    <= 8'd32;
        th_gb    <= 8'd32;
        adapt_ok <= 1'b0;
    end
    else begin
        vsync_d <= vsync;

        case(sc_state)
            SC_IDLE: begin
                if(vsync_rise) begin
                    //  thr_cnt = total * PCT / 100
                    thr_cnt  <= (total * PCT) / 8'd100;
                    sc_i     <= 9'd255;
                    cum_gr   <= 20'd0;
                    cum_gb   <= 20'd0;
                    hit_gr   <= 1'b0;
                    hit_gb   <= 1'b0;
                    sc_state <= SC_RUN;
                end
                else if(!en) begin
                    //  关掉自适应：直接透传手动值（行为与改动前一致）
                    th_gr    <= th_gr_man;
                    th_gb    <= th_gb_man;
                    adapt_ok <= 1'b0;
                end
                else if(de && (total != 20'hFFFFF)) begin
                    total <= total + 20'd1;
                end
            end

            SC_RUN: begin
                cum_gr <= cum_gr + hgr_rd;
                cum_gb <= cum_gb + hgb_rd;

                if(!hit_gr && ((cum_gr + hgr_rd) >= thr_cnt)) begin
                    hit_gr <= 1'b1;
                    thv_gr <= sc_i[7:0];
                end
                if(!hit_gb && ((cum_gb + hgb_rd) >= thr_cnt)) begin
                    hit_gb <= 1'b1;
                    thv_gb <= sc_i[7:0];
                end

                if(sc_i == 9'd0) sc_state <= SC_END;
                else             sc_i     <= sc_i - 9'd1;
            end

            default: begin   // SC_END
                total <= 20'd0;
                if(en && (total >= MIN_TOTAL) && hit_gr) begin
                    th_gr    <= thv_gr;
                    th_gb    <= hit_gb ? thv_gb : thv_gr;
                    adapt_ok <= 1'b1;
                end
                else if(!en) begin
                    th_gr    <= th_gr_man;
                    th_gb    <= th_gb_man;
                    adapt_ok <= 1'b0;
                end
                //  en 开着但本帧样本太少 -> 保持上一次的自适应值不变
                sc_state <= SC_IDLE;
            end
        endcase
    end
end

endmodule
