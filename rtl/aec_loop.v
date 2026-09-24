`timescale 1ns / 1ps
//****************************************************************************************//
// File name:           aec_loop
// Descriptions:        PL 侧自动曝光闭环（P6）—— 不再手猜曝光值
//
//   为什么需要（这是对之前那次「黑屏事故」的正确修复方式）：
//     上次为了抗反光，把曝光写死成 0x0200（**拍脑袋猜的**），结果对现场太暗 -> 传感器
//     输出近全黑 -> 而 lcd_bl 是常亮的 -> 屏幕全黑，看起来像「屏坏了」。
//     根因不是「不该锁曝光」，而是「不该用一个没标定的常数」。
//     正确的做法是让 PL 自己闭环：统计过曝像素比例，据此调曝光。
//
//   判据（每帧一次）：
//     过曝像素 = r8>200 且 g8>200 且 b8>200（三通道都接近饱和 = 白光/镜面反射）
//     - 过曝比例 > SAT_HI%  -> 曝光降一档（镜面反光进画面了）
//     - 过曝比例 < SAT_LO%  -> 曝光升一档（画面太暗，绿色差值会缩小）
//     - 在两者之间           -> 不动（死区，防止来回抖）
//     调整速率限制：每 AEC_DIV 帧最多动一次。
//
//   安全设计（重要）：
//     - 默认 AEC_EN = 0，此时本模块**不产生任何 I2C 请求**，相机行为与改动前完全一致
//     - 开启后需要先写 0x3503=0x03 把 AEC 切成手动，再写 0x3500/0x3502 清零，之后才调
//       0x3501（曝光高字节），全过程通过 req_* 握手请求 I2C 引擎
//     - 曝光值被夹在 [EXP_MIN, EXP_MAX]，不可能被调到 0
//
//   资源：约 260 LUT / 150 FF，0 BRAM。
//****************************************************************************************//
module aec_loop #(
    parameter [7:0] EXP_DEF = 8'h08,   // 初始曝光高字节 -> 曝光 = 0x0800
    parameter [7:0] EXP_MIN = 8'h01,   // 下限（很暗，但绝不是 0）
    parameter [7:0] EXP_MAX = 8'h40,   // 上限（很亮）
    parameter [7:0] SAT_HI  = 8'd8,    // 过曝比例上限（%）
    parameter [7:0] SAT_LO  = 8'd1,    // 过曝比例下限（%）
    parameter [7:0] AEC_DIV = 8'd16    // 每多少帧最多调一次
)(
    input              clk        ,
    input              rst_n      ,
    input              vsync      ,
    input              de         ,
    input      [7:0]   r8         ,
    input      [7:0]   g8         ,
    input      [7:0]   b8         ,

    input              en         ,   // AEC_EN
    input              init_done  ,   // 相机初始化完成（sys_init_done）

    //  I2C 写请求（交给 ov5640_lcd 里的仲裁器）
    output reg         req_exec   ,
    output reg [15:0]  req_addr   ,
    output reg [7:0]   req_data   ,
    input              req_done   ,

    output reg [7:0]   exp_cur    ,   // 当前曝光高字节（可观测 / 可上报）
    output reg [31:0]  sat_cnt        // 上一帧过曝像素数（可观测）
);

//localparam
localparam ST_IDLE = 2'd0, ST_SETUP = 2'd1, ST_READY = 2'd2;

//reg define
reg  [31:0] sat_acc  ;
reg  [31:0] tot_acc  ;
reg  [1:0]  state    ;
reg  [2:0]  setup_i  ;
reg         waiting  ;      // 正在等 I2C 写完（必须等，否则四条请求会在八拍内全喷出去）
reg  [7:0]  divcnt   ;
reg         vsync_d  ;
reg         go       ;
reg  [7:0]  exp_next ;

//wire define
wire vsync_rise = vsync & ~vsync_d;
wire vsync_fall = ~vsync & vsync_d;
wire sat_pix    = (r8 > 8'd200) && (g8 > 8'd200) && (b8 > 8'd200);

//*****************************************************
//**                    main code
//*****************************************************

always @(posedge clk or negedge rst_n) begin
    if(!rst_n) vsync_d <= 1'b0;
    else       vsync_d <= vsync;
end

//-------------------------------------------------------
// 帧内统计
//-------------------------------------------------------
always @(posedge clk or negedge rst_n) begin
    if(!rst_n) begin
        sat_acc <= 32'd0;
        tot_acc <= 32'd0;
    end
    else if(vsync_rise) begin
        sat_acc <= 32'd0;
        tot_acc <= 32'd0;
    end
    else if(de) begin
        if(tot_acc != 32'hFFFFFF) tot_acc <= tot_acc + 32'd1;
        if(sat_pix && (sat_acc != 32'hFFFFFF)) sat_acc <= sat_acc + 32'd1;
    end
end

//-------------------------------------------------------
// 帧末判定：算出下一档曝光（组合），再由状态机发出请求
//   用乘法比较代替除法：sat*100 > tot*SAT_HI  <=>  比例 > SAT_HI%
//-------------------------------------------------------
wire [31:0] sat_x100 = sat_acc * 32'd100;
wire [31:0] hi_line  = tot_acc * SAT_HI;
wire [31:0] lo_line  = tot_acc * SAT_LO;

wire too_bright = (tot_acc > 32'd1000) && (sat_x100 > hi_line);
wire too_dark   = (tot_acc > 32'd1000) && (sat_x100 < lo_line);

//-------------------------------------------------------
// 帧末节流
//-------------------------------------------------------
always @(posedge clk or negedge rst_n) begin
    if(!rst_n) divcnt <= 8'd0;
    else if(vsync_fall) divcnt <= (divcnt == AEC_DIV - 1) ? 8'd0 : (divcnt + 8'd1);
end

//-------------------------------------------------------
// 请求状态机
//   0x3503 = 0x03 (AEC/AGC 手动) -> 0x3500 = 0x00 (曝光高 4 位) -> 0x3502 = 0x00 (低 8 位)
//   之后每 AEC_DIV 帧按统计量微调 0x3501（曝光 [15:8]）
//-------------------------------------------------------
always @(posedge clk or negedge rst_n) begin
    if(!rst_n) begin
        state    <= ST_IDLE;
        setup_i  <= 3'd0;
        waiting  <= 1'b0;
        req_exec <= 1'b0;
        req_addr <= 16'd0;
        req_data <= 8'd0;
        exp_cur  <= EXP_DEF;
        sat_cnt  <= 32'd0;
    end
    else begin
        req_exec <= 1'b0;

        case(state)
            ST_IDLE: begin
                if(!en) begin
                    state   <= ST_IDLE;
                    exp_cur <= EXP_DEF;
                end
                else if(init_done) begin
                    setup_i <= 3'd0;
                    state   <= ST_SETUP;
                end
            end

            ST_SETUP: begin
                if(!waiting && !req_exec) begin
                    case(setup_i)
                        3'd0: begin req_addr <= 16'h3503; req_data <= 8'h03; end
                        3'd1: begin req_addr <= 16'h3500; req_data <= 8'h00; end
                        3'd2: begin req_addr <= 16'h3502; req_data <= 8'h00; end
                        default: begin req_addr <= 16'h3501; req_data <= exp_cur; end
                    endcase
                    req_exec <= 1'b1;
                    waiting  <= 1'b1;
                end
                else if(waiting && req_done) begin
                    waiting <= 1'b0;
                    if(setup_i == 3'd4) state <= ST_READY;
                    else                setup_i <= setup_i + 3'd1;
                end
            end

            default: begin   // ST_READY
                if(!en) begin
                    state <= ST_IDLE;
                end
                else if(vsync_fall) begin
                    sat_cnt <= sat_acc;
                    if((divcnt == AEC_DIV - 1) && !req_exec) begin
                        if(too_bright && (exp_cur > EXP_MIN)) begin
                            exp_cur  <= exp_cur - 8'd1;
                            req_addr <= 16'h3501;
                            req_data <= exp_cur - 8'd1;
                            req_exec <= 1'b1;
                        end
                        else if(too_dark && (exp_cur < EXP_MAX)) begin
                            exp_cur  <= exp_cur + 8'd1;
                            req_addr <= 16'h3501;
                            req_data <= exp_cur + 8'd1;
                            req_exec <= 1'b1;
                        end
                    end
                end
            end
        endcase
    end
end

endmodule
