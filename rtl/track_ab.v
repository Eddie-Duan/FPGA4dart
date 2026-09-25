`timescale 1ns / 1ps
//****************************************************************************************//
// File name:           track_ab
// Descriptions:        时序门控 + alpha-beta 跟踪（P4）
//
//   为什么需要（这是 dart 的 PL 里**没有**的东西，也是本专案最能拉开差距的地方）：
//     镜面反射造成的失败不是「稳定错」，而是「偶发一两帧突然丢失」。原来的设计每帧独立
//     判决，丢一帧就是丢一帧，下游（云台/飞控）拿到的是一个方波。
//     这里加两道时间维度的过滤：
//       1) 门控：新观测量必须落在上一帧滤波位置的 GATE 像素半径内才被接受
//          -> 画面别处突然冒出来的绿块（反光、别人的灯）直接被拒
//       2) 持续性：连续 HIT_N 帧命中才置 valid；连续 LOST_N 帧丢失才撤销
//          -> 不会因为一帧丢失就把目标丢掉；短时丢帧时用速度外推顶上
//     再叠一个 alpha-beta 滤波，给出平滑位置 + 速度（速度本身就是外推的依据）。
//
//   时序：blob_track 在 vsync 下降沿更新输出，本模块在**再晚一拍**采样
//         （fall -> frame_end），保证拿到的是刚结束那一帧的结果。
//   alpha-beta：
//       res = meas - pred         （pred 是上一帧算出的预测位置）
//       pos = pred + res * ALPHA  （平滑位置）
//       vel = vel  + res * BETA   （速度估计）
//       pred= pos  + vel          （下一帧的预测位置 = 门控中心）
//   默认 ALPHA=0.5、BETA=0.25，都是 Q8 定点，只用移位乘法，不占 DSP。
//
//   资源：约 300 LUT / 200 FF，0 BRAM，0 DSP。
//****************************************************************************************//
module track_ab #(
    parameter AW       = 10     ,
    parameter WIDTH    = 800    ,
    parameter HEIGHT   = 480    ,
    parameter HIT_N    = 2      ,   // 连续命中多少帧才报有效
    parameter LOST_N   = 6      ,   // 连续丢失多少帧才放弃
    parameter [7:0] ALPHA_Q8 = 8'd128,  // 0.5
    parameter [7:0] BETA_Q8  = 8'd64    // 0.25
)(
    input                 clk        ,
    input                 rst_n      ,
    input                 vsync      ,

    input      [AW-1:0]   gate       ,   // 门控半径（像素，运行时可变；UART 0x08）
    input                 raw_valid  ,   // blob_track 本帧是否找到团块
    input      [AW-1:0]   raw_cx     ,   // 外框中心
    input      [AW-1:0]   raw_cy     ,
    input      [AW-1:0]   raw_ay     ,   // 瞄准点 y（用来反推瞄准偏移）

    output reg            valid      ,   // 跟踪输出有效
    output reg [AW-1:0]   cx         ,
    output reg [AW-1:0]   cy         ,
    output reg [AW-1:0]   ax         ,
    output reg [AW-1:0]   ay         ,
    output reg [4:0]      lost_cnt       // 当前连续丢失帧数（可观测）
);

//localparam
localparam signed [AW+2:0] W_MAX = WIDTH  - 1;
localparam signed [AW+2:0] H_MAX = HEIGHT - 1;

//reg define
reg                    vsync_d   ;
reg                    frame_end ;
reg                    tracking  ;
reg  [4:0]             hit_cnt   ;
reg  [4:0]             miss_cnt  ;
reg  signed [AW+2:0]   px, py    ;   // 预测位置
reg  signed [AW+1:0]   vx, vy    ;   // 速度估计
reg  signed [AW+2:0]   aim_off   ;   // 外框中心 - 瞄准点 y（正值向上）

//wire define
wire vsync_fall = ~vsync & vsync_d;

//*****************************************************
//**                    main code
//*****************************************************

always @(posedge clk or negedge rst_n) begin
    if(!rst_n) begin
        vsync_d   <= 1'b0;
        frame_end <= 1'b0;
    end
    else begin
        vsync_d   <= vsync;
        frame_end <= vsync_fall;      // 比 blob_track 的输出再晚一拍
    end
end

//-------------------------------------------------------
// 门控判定（组合）
//   还没建立跟踪时无条件接受（首帧）
//-------------------------------------------------------
wire signed [AW+2:0] dx = $signed({1'b0, raw_cx}) - px;
wire signed [AW+2:0] dy = $signed({1'b0, raw_cy}) - py;
wire signed [AW+2:0] gate_s = $signed({1'b0, gate});
wire gate_ok = (!tracking) || ((dx >= -gate_s) && (dx <= gate_s) &&
                               (dy >= -gate_s) && (dy <= gate_s));

//-------------------------------------------------------
// alpha-beta 中间量（组合）
//-------------------------------------------------------
wire signed [AW+2:0] sx  = (dx * ALPHA_Q8) >>> 8;   // alpha 修正量
wire signed [AW+2:0] sy  = (dy * ALPHA_Q8) >>> 8;
wire signed [AW+1:0] bx  = (dx * BETA_Q8 ) >>> 8;   // beta 修正量
wire signed [AW+1:0] by  = (dy * BETA_Q8 ) >>> 8;

wire signed [AW+2:0] nx  = px + sx;                 // 新平滑位置
wire signed [AW+2:0] ny  = py + sy;
wire signed [AW+1:0] nvx = vx + bx;                 // 新速度
wire signed [AW+1:0] nvy = vy + by;
wire signed [AW+2:0] npx = nx + nvx;                // 新预测位置
wire signed [AW+2:0] npy = ny + nvy;

wire [4:0] hit_next = (hit_cnt  == 5'd31) ? 5'd31 : (hit_cnt  + 5'd1);
wire [4:0] mis_next = (miss_cnt == 5'd31) ? 5'd31 : (miss_cnt + 5'd1);

//-------------------------------------------------------
// 输出钳位
//-------------------------------------------------------
function [AW-1:0] clampw;
    input signed [AW+2:0] v;
    begin
        if(v < 0)          clampw = {AW{1'b0}};
        else if(v > W_MAX) clampw = W_MAX[AW-1:0];
        else               clampw = v[AW-1:0];
    end
endfunction

function [AW-1:0] clamph;
    input signed [AW+2:0] v;
    begin
        if(v < 0)          clamph = {AW{1'b0}};
        else if(v > H_MAX) clamph = H_MAX[AW-1:0];
        else               clamph = v[AW-1:0];
    end
endfunction

//-------------------------------------------------------
// 帧末更新
//-------------------------------------------------------
always @(posedge clk or negedge rst_n) begin
    if(!rst_n) begin
        tracking <= 1'b0;
        valid    <= 1'b0;
        hit_cnt  <= 5'd0;
        miss_cnt <= 5'd0;
        lost_cnt <= 5'd0;
        px <= 0; py <= 0; vx <= 0; vy <= 0;
        cx <= {AW{1'b0}}; cy <= {AW{1'b0}};
        ax <= {AW{1'b0}}; ay <= {AW{1'b0}};
        aim_off <= 0;
    end
    else if(frame_end) begin
        if(raw_valid && gate_ok) begin
            //  接受这一帧
            //  首次捕获（之前没在跟踪）：位置直接取测量值、速度归零。
            //  否则 alpha-beta 会把「从 0 到目标的整段距离」当成速度
            //  （v = BETA*400 = 100），下一帧预测位置直接冲到 300，
            //  真正的目标 400 反倒落在门控半径(96)之外被拒掉，
            //  valid 就永远建立不起来 —— 单元测试 6 项全挂就是这个原因。
            if(!tracking) begin
                px <= $signed({1'b0, raw_cx});
                py <= $signed({1'b0, raw_cy});
                vx <= 0;
                vy <= 0;
                cx <= raw_cx;
                cy <= raw_cy;
                ax <= raw_cx;
                ay <= raw_ay;
            end
            else begin
                px  <= npx;
                py  <= npy;
                vx  <= nvx;
                vy  <= nvy;
                cx  <= clampw(nx);
                cy  <= clamph(ny);
                ax  <= clampw(nx);
                ay  <= clamph(ny - aim_off);
            end
            aim_off <= $signed({1'b0, raw_cy}) - $signed({1'b0, raw_ay});
            hit_cnt  <= hit_next;
            miss_cnt <= 5'd0;
            lost_cnt <= 5'd0;
            tracking <= 1'b1;
            valid    <= (hit_next >= HIT_N);       // 连续命中够多才报有效
        end
        else begin
            //  本次未接受
            hit_cnt  <= (mis_next >= LOST_N) ? 5'd0 : hit_cnt;
            miss_cnt <= mis_next;
            lost_cnt <= mis_next;
            //  短时丢帧：用速度外推顶上，位置不跳变
            px <= npx;
            py <= npy;
            cx <= clampw(px + vx);
            cy <= clamph(py + vy);
            ax <= clampw(px + vx);
            ay <= clamph(py + vy - aim_off);
            if(mis_next >= LOST_N) begin
                tracking <= 1'b0;
                valid    <= 1'b0;
                vx <= 0; vy <= 0;
            end
            else begin
                valid <= tracking;                 // 丢帧但还没到放弃阈值 -> 保持有效
            end
        end
    end
end

endmodule
