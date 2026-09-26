`timescale 1ns / 1ps
//****************************************************************************************//
// File name:           syn_target
// Descriptions:        板上合成靶标发生器（P13a）—— 不用相机/灯/上位机就能自检全链路
//
//   为什么要：
//     现场最麻烦的是「没有可复现的目标」：真人拿灯晃，速度不可控、每次都不一样，
//     预测/弹道这类依赖时序的功能根本没法验。这个模块自己造一个匀速往返的绿圆，
//     打开后顶替相机像素 -> 「分割 -> 团块 -> 预测 -> 弹道 -> 上报/显示」整条链路
//     都能在板子上跑，而且目标速度是精确已知的（可以直接和上报的 vx_q4 对表）。
//
//   怎么用：
//     UART 写 0x0F = 1 打开（写 0 回到相机）；0x0D 改速度（有符号 Q4 px/帧，
//     80 = 5.0 px/帧，负数反向）；0x0E 改半径（默认 60 -> 直径 120px，落在推荐取景范围）。
//
//   坐标约定（关键）：
//     x_v / y_cnt 与 data_v 是同一拍（都是 de 打一拍后的），所以 pix 用组合输出、
//     直接替 data_v 就是逐像素对齐的；圆画在 (400,240)，经 8 像素形态学偏移后
//     下游报出来正好是 (408,248)，与仿真期望一致。
//
//   资源：2 个平方 + 比较器，约 50 LUT / 60 FF / 2~4 DSP（组合输出，20ns 内够用）。
//         默认关闭时也照占（开关是运行时的）；想彻底省掉就把整个例化放进 generate。
//****************************************************************************************//
module syn_target #(
    parameter AW     = 10    ,   // 坐标位宽
    parameter WIDTH  = 800   ,   // 图像宽
    parameter HEIGHT = 480   ,   // 图像高
    parameter [15:0] PIX_GREEN = 16'h750E,   // 目标色（G-R=G-B=44，与相机/仿真一致）
    parameter [15:0] PIX_BG    = 16'h8410    // 背景（灰，绝不会被判成绿）
)(
    input                clk     ,
    input                rst_n   ,
    input                vsync   ,   // 帧起始脉冲：每帧动一次
    input      [AW-1:0]  x       ,   // 当前像素 x（x_v）
    input      [AW-1:0]  y       ,   // 当前行（y_cnt，1 基）
    input      [7:0]     spd_q4  ,   // 有符号 Q4 px/帧
    input      [AW-1:0]  rad     ,   // 半径（像素）
    output reg [15:0]    pix     ,   // 合成像素（打一拍；x 比较时 +1 抵消这拍延迟）
    output     [AW-1:0]  cx          // 当前圆心 x（调试/ILA）
);

//localparam
localparam [AW-1:0] X_MAX = WIDTH - 1;
localparam [AW-1:0] Y_MID = HEIGHT / 2;

//reg define
reg  signed [23:0] cx_q4 ;       // 圆心 x（Q4）
reg  signed [23:0] vx_q4 ;       // 当前速度（Q4，碰边取反 -> 往返）
reg        [23:0]  r2    ;       // 半径平方
reg  [AW-1:0]      rad_d ;       // 上一拍的半径（检测半径被改）

//wire define
wire signed [23:0] spd_s  = $signed({{16{spd_q4[7]}}, spd_q4});
wire signed [23:0] lo_lim = $signed({14'd0, rad}) <<< 4;
wire signed [23:0] hi_lim = $signed({14'd0, (X_MAX - rad)}) <<< 4;
//  用「新速度」先试探一次：越界就把速度取反（改 0x0D 立即生效，不拖一帧）
wire signed [23:0] trial  = cx_q4 + spd_s;
wire               flip   = (trial > hi_lim) || (trial < lo_lim);
wire signed [23:0] v_new  = flip ? -spd_s : spd_s;
wire signed [23:0] nx     = cx_q4 + v_new;
wire               bounce = (nx > hi_lim) || (nx < lo_lim);
wire signed [23:0] nx_cl  = bounce ? ((nx > hi_lim) ? hi_lim : lo_lim) : nx;
wire signed [23:0] cx_now = cx_q4 >>> 4;

//  圆方程的经典化简：dx^2 + dy^2 <= r2  <=>  dx^2 <= (r2 - dy^2)
//  r2 - dy^2 只跟行有关，用一个寄存器逐拍算好（y_cnt 一行内不变，行间消隐足够跟上）
//  -> 逐像素只剩「一个平方 + 一个比较」，50MHz（20ns）下才收得住。
//  契约：换行后要过至少一个时钟 row_t 才跟上（真实光栅的行间消隐天然满足）。
wire signed [AW:0] dys  = $signed({1'b0, y}) - $signed({1'b0, Y_MID});
wire        [AW:0] dya  = dys[AW] ? (~dys + 1'b1) : dys;
wire [2*AW+1:0]    dya2 = dya*dya;

//  必须有符号：dy^2 > r2 时 r2-dy^2 是负数 -> 那一行一个像素都不该命中。
//  如果夹到 0，dx=0 那一点会因为「0 <= 0」被凭空画出来（实测踩到）。
reg signed [24:0] row_t;
always @(posedge clk or negedge rst_n) begin
    if(!rst_n) row_t <= 25'sd0;
    else       row_t <= $signed({1'b0, r2}) - $signed({4'b0, dya2});
end

//  打拍让图左移 1 像素 -> 比较时把 x 加 1 抵消回去（见文件头说明）
wire [AW:0]        x_eff = {1'b0, x} + 1'b1;
wire signed [AW:0] dxs  = $signed(x_eff) - $signed({1'b0, cx_now[AW-1:0]});
wire        [AW:0] dxa = dxs[AW] ? (~dxs + 1'b1) : dxs;
wire [2*AW+1:0]    dxa2 = dxa*dxa;

assign cx  = cx_now[AW-1:0];

always @(posedge clk or negedge rst_n) begin
    if(!rst_n) pix <= PIX_BG;
    else       pix <= ($signed({4'b0, dxa2}) <= row_t) ? PIX_GREEN : PIX_BG;
end
//  有符号比较（两边都补零扩到 25 位）放在上面的时序块里

//-------------------------------------------------------
// 每帧动一次（vsync 脉冲）；碰到边缘就把速度取反
//-------------------------------------------------------
always @(posedge clk or negedge rst_n) begin
    if(!rst_n) begin
        cx_q4 <= $signed({14'd0, (WIDTH/2)}) <<< 4;
        vx_q4 <= 24'sd80;                 // 默认 5.0 px/帧
    end
    else if(vsync) begin
        cx_q4 <= nx_cl;
        vx_q4 <= v_new;
    end
end

//-------------------------------------------------------
// 半径平方：每帧更新一次（默认 60 -> 3600）
//-------------------------------------------------------
always @(posedge clk or negedge rst_n) begin
    if(!rst_n) begin
        rad_d <= {AW{1'b0}};
        r2    <= 24'd0;
    end
    else begin
        rad_d <= rad;
        if(rad != rad_d) r2 <= {14'd0, rad} * {14'd0, rad};
    end
end

endmodule
