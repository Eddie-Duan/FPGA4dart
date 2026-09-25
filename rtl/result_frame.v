`timescale 1ns / 1ps
//****************************************************************************************//
// File name:           result_frame
// Descriptions:        结果上报帧（P1）：把检测结果打包成定长 16 字节从 UART 发出
//
//   为什么需要：
//     现在结果只有 LCD / 数码管 / LED，都是「给人看」的。dart 是靠 PL 把结果 DMA 给 PS，
//     再由 PS 上的程序跟飞控通信。我们没有 PS，所以必须直接从 PL 出一个机器可读的接口。
//
//   帧格式（16 字节，小端无意义，全部是裸整数）：
//     0  0xA5                     帧头1
//     1  0x5A                     帧头2
//     2  flags                    b0=valid b1=adapt_ok b2=二值显示
//     3  cx[15:8]   4  cx[7:0]    外框中心 x
//     5  cy[15:8]   6  cy[7:0]    外框中心 y
//     7  ax[15:8]   8  ax[7:0]    瞄准点 x
//     9  ay[15:8]  10  ay[7:0]    瞄准点 y
//     11 w                        外框宽（0..255，超过截断）
//     12 area>>7                  面积粗值（0..255）
//     13 fill_q8                  填充率 x256（圆约 201）
//     14 blob_cnt                 本帧合格团块数
//     15 checksum                 byte2..byte14 逐字节异或
//
//   发送节流：每 TX_DIV 帧发一次（默认 8 -> 30fps 下约 3.75Hz），避免占满串口。
//   资源：约 120 LUT / 180 FF。
//****************************************************************************************//
//   v2（当前，24 字节）：前 15 个字节的含义与 v1 完全一致，后面接预测字段
//     15 vx_hi  16 vx_lo          速度估计 x（Q4，有符号，1 px/帧 = 16）
//     17 vy_hi  18 vy_lo          速度估计 y（Q4，有符号）
//     19 px_hi  20 px_lo          预测灯心 x（LEAD 帧之后）
//     21 py_hi  22 py_lo          预测灯心 y
//     23 checksum                 byte2..byte22 逐字节异或
//   flags.b7 = 1 表示 v2 帧：旧解析器算校验时用的是 byte2..byte14，
//   与新帧必然对不上 -> 会【安全地丢弃】而不是读出乱码。
//   预测瞄准点 = (px, py - w*AIM_H_Q8/256)，接收端按自己的 AIM_H_Q8 算即可。
//
module result_frame #(
    parameter CLK_FREQ = 25_000_000,
    parameter BAUD     = 115200,
    parameter TX_DIV   = 8
)(
    input              clk       ,
    input              rst_n     ,
    input              frame_tick,        // 每帧一个脉冲
    input              valid     ,
    input      [9:0]   cx        ,
    input      [9:0]   cy        ,
    input      [9:0]   ax        ,
    input      [9:0]   ay        ,
    input      [10:0]  bw        ,
    input      [31:0]  area      ,
    input      [7:0]   fill_q8   ,
    input      [2:0]   blob_cnt  ,
    input              adapt_ok  ,
    input              disp_bin  ,
    input               pred_ok   ,   // 预测有效（连续 >= 2 帧）
    input               moving    ,   // 目标在动
    input               far_small ,   // 命中的是宽松档（小而远的目标）
    input signed [15:0] vx_q4     ,
    input signed [15:0] vy_q4     ,
    input      [9:0]    px        ,   // 预测灯心
    input      [9:0]    py        ,
    output             txd
);

//localparam
localparam S_IDLE = 2'd0, S_REQ = 2'd1, S_WAIT = 2'd2;

//reg define
reg  [7:0]  b0, b1, b2, b3, b4, b5, b6, b7;
reg  [7:0]  b8, b9, b10, b11, b12, b13, b14, b15;
reg  [7:0]  b16, b17, b18, b19, b20, b21, b22, b23;
reg  [4:0]  idx     ;
reg  [1:0]  state   ;
reg  [7:0]  divcnt  ;
reg  [7:0]  tx_byte ;
reg         tx_start;
reg  [7:0]  chk     ;

//wire define
wire        tx_busy, tx_done;

//*****************************************************
//**                    main code
//*****************************************************

uart_tx #(.CLK_FREQ(CLK_FREQ), .BAUD(BAUD)) u_tx (
    .clk(clk), .rst_n(rst_n),
    .tx_start(tx_start), .tx_data(tx_byte),
    .tx_busy(tx_busy), .tx_done(tx_done), .txd(txd)
);

//-------------------------------------------------------
// 帧节流
//-------------------------------------------------------
wire tx_now = frame_tick && (divcnt == TX_DIV - 1);

always @(posedge clk or negedge rst_n) begin
    if(!rst_n) divcnt <= 8'd0;
    else if(frame_tick) divcnt <= (divcnt == TX_DIV - 1) ? 8'd0 : (divcnt + 8'd1);
end

//-------------------------------------------------------
// 帧末打包
//-------------------------------------------------------
always @(posedge clk or negedge rst_n) begin
    if(!rst_n) begin
        b0<=8'hA5; b1<=8'h5A; b2<=8'h00; b3<=8'h00; b4<=8'h00; b5<=8'h00;
        b6<=8'h00; b7<=8'h00; b8<=8'h00; b9<=8'h00; b10<=8'h00; b11<=8'h00;
        b12<=8'h00; b13<=8'h00; b14<=8'h00; b15<=8'h00;
        b16<=8'h00; b17<=8'h00; b18<=8'h00; b19<=8'h00;
        b20<=8'h00; b21<=8'h00; b22<=8'h00; b23<=8'h00;
    end
    else if(tx_now) begin
        b0 <= 8'hA5;
        b1 <= 8'h5A;
        b2 <= {1'b1, far_small, moving, pred_ok, 1'b0,
               disp_bin, adapt_ok, valid};   // b7=1 -> v2 帧
        b3 <= {6'b0, cx[9:8]};          // cx 10bit，高字节只低 2 位有效
        b4 <= cx[7:0];
        b5 <= {6'b0, cy[9:8]};
        b6 <= cy[7:0];
        b7 <= {6'b0, ax[9:8]};
        b8 <= ax[7:0];
        b9 <= {6'b0, ay[9:8]};
        b10<= ay[7:0];
        b11<= (bw > 11'd255) ? 8'd255 : bw[7:0];
        b12<= (area[31:7] > 32'd255) ? 8'd255 : area[14:7];
        b13<= (fill_q8 == 8'd255) ? 8'd255 : fill_q8;
        b14<= {5'b0, blob_cnt};
        b15<= vx_q4[15:8];
        b16<= vx_q4[7:0];
        b17<= vy_q4[15:8];
        b18<= vy_q4[7:0];
        b19<= {6'b0, px[9:8]};
        b20<= px[7:0];
        b21<= {6'b0, py[9:8]};
        b22<= py[7:0];
        b23<= {1'b1, far_small, moving, pred_ok, 1'b0,
               disp_bin, adapt_ok, valid}
              ^ cx[9:8] ^ cx[7:0] ^ cy[9:8] ^ cy[7:0]
              ^ ax[9:8] ^ ax[7:0] ^ ay[9:8] ^ ay[7:0]
              ^ ((bw > 11'd255) ? 8'd255 : bw[7:0])
              ^ ((area[31:7] > 32'd255) ? 8'd255 : area[14:7])
              ^ fill_q8
              ^ {5'b0, blob_cnt}
              ^ vx_q4[15:8] ^ vx_q4[7:0] ^ vy_q4[15:8] ^ vy_q4[7:0]
              ^ {6'b0, px[9:8]} ^ px[7:0] ^ {6'b0, py[9:8]} ^ py[7:0];
    end
end

//-------------------------------------------------------
// 发送状态机
//-------------------------------------------------------
wire [7:0] mux_byte = (idx == 5'd0 ) ? b0  : (idx == 5'd1 ) ? b1  :
                      (idx == 5'd2 ) ? b2  : (idx == 5'd3 ) ? b3  :
                      (idx == 5'd4 ) ? b4  : (idx == 5'd5 ) ? b5  :
                      (idx == 5'd6 ) ? b6  : (idx == 5'd7 ) ? b7  :
                      (idx == 5'd8 ) ? b8  : (idx == 5'd9 ) ? b9  :
                      (idx == 5'd10) ? b10 : (idx == 5'd11) ? b11 :
                      (idx == 5'd12) ? b12 : (idx == 5'd13) ? b13 :
                      (idx == 5'd14) ? b14 : (idx == 5'd15) ? b15 :
                      (idx == 5'd16) ? b16 : (idx == 5'd17) ? b17 :
                      (idx == 5'd18) ? b18 : (idx == 5'd19) ? b19 :
                      (idx == 5'd20) ? b20 : (idx == 5'd21) ? b21 :
                      (idx == 5'd22) ? b22 : b23;

always @(posedge clk or negedge rst_n) begin
    if(!rst_n) begin
        state    <= S_IDLE;
        idx      <= 4'd0;
        tx_start <= 1'b0;
        tx_byte  <= 8'd0;
    end
    else begin
        tx_start <= 1'b0;
        case(state)
            S_IDLE: begin
                if(tx_now) begin
                    idx   <= 5'd0;
                    state <= S_REQ;
                end
            end
            S_REQ: begin
                if(!tx_busy) begin
                    tx_byte  <= mux_byte;
                    tx_start <= 1'b1;
                    state    <= S_WAIT;
                end
            end
            S_WAIT: begin
                if(tx_done) begin
                    if(idx == 5'd23) state <= S_IDLE;
                    else begin
                        idx   <= idx + 5'd1;
                        state <= S_REQ;
                    end
                end
            end
            default: state <= S_IDLE;
        endcase
    end
end

endmodule
