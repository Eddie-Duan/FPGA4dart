`timescale 1ns / 1ps
//****************************************************************************************//
// File name:           result_frame
// Descriptions:        结果上报帧（P1/P11）—— 定长 34 字节 + CRC16 + 帧序号
//
//   为什么需要：本工程 PL 里没有 PS，所以必须自己给云台 / 飞控一个可直接用的接口。
//
//   帧格式（v3 = 34 字节，115200 8N1，多字节先发高字节）
//     0   0xA5                    帧头1
//     1   0x5A                    帧头2
//     2   flags                   b7=1(扩展帧) b6=far_small b5=moving b4=pred_ok
//                                 b3=dist_ok b2=二值显示 b1=adapt_ok b0=valid
//     3-4   cx                    当前外框中心 x（预测前的观测值）
//     5-6   cy
//     7-8   ax                    当前帧几何瞄准点 x（v1 语义不变，便于对照）
//     9-10  ay
//     11    w                     外框宽（饱和到 255）
//     12    area>>7               面积粗值（饱和到 255）
//     13    fill_q8               填充率 x256（圆的理论值约 201）
//     14    blob_cnt              本帧合格团块数
//     15-16 vx_q4                 速度估计 x（Q4 有符号，16 = 1 px/帧）
//     17-18 vy_q4                 速度估计 y（Q4 有符号）
//     19-20 px                    预测灯心 x（LEAD 帧之后）
//     21-22 py                    预测灯心 y
//     23-24 dist_cm               距离（cm，由表观宽度反推；dist_ok=0 时无意义）
//     25-26 drop_px               该距离下的弹道下坠补偿（像素，已按 DROP_SCALE 修正）
//     27-28 fx                    最终建议瞄准点 x = px
//     29-30 fy                               = py - w*AIM_H_Q8/256 - drop_px
//     31    seq                   帧序号（每帧 +1，回绕；接收端据此发现丢帧）
//     32-33 crc16                 CRC-16/CCITT-FALSE（poly 0x1021、初值 0xFFFF、
//                                 MSB 先），对 byte2..byte31 计算，高字节先发
//
//   云台直接用 fx / fy（已经把灯心偏移、速度提前量、下坠补偿都算进去了）；
//   只想看原始观测就用 cx/cy（当前）与 px/py（预测）。
//
//   v1（16 字节）是旧格式：flags.b7=0，byte15 = byte2..byte14 的逐字节异或。
//   扩展帧把 b7 置 1，旧解析器按 v1 算校验必然不过 -> 安全丢弃，不会读出垃圾。
//   （v2 的 24 字节布局只存在过一轮，没有上过板，已取消。）
//
//   发送节奏：每 TX_DIV 帧发一条（默认 8 -> 30fps 下约 3.75Hz，一帧 34 字节约 30ms）。
//   CRC 逐位串行（240 拍）而不是 256 级组合异或：省时序，代价可以忽略。
//   资源：约 180 LUT / 420 FF / 0 BRAM。
//****************************************************************************************//
module result_frame #(
    parameter CLK_FREQ = 25_000_000,
    parameter BAUD     = 115200,
    parameter TX_DIV   = 8
)(
    input                clk       ,
    input                rst_n     ,
    input                frame_tick,        // 每帧一个脉冲

    //  ---- v1 字段 ----
    input                valid     ,
    input      [9:0]     cx        ,
    input      [9:0]     cy        ,
    input      [9:0]     ax        ,
    input      [9:0]     ay        ,
    input      [10:0]    bw        ,
    input      [31:0]    area      ,
    input      [7:0]     fill_q8   ,
    input      [2:0]     blob_cnt  ,
    input                adapt_ok  ,
    input                disp_bin  ,
    //  ---- P10 预测 ----
    input                pred_ok   ,
    input                moving    ,
    input                far_small ,
    input signed [15:0]  vx_q4     ,
    input signed [15:0]  vy_q4     ,
    input      [9:0]     px        ,
    input      [9:0]     py        ,
    //  ---- P11 弹道 ----
    input                dist_ok   ,
    input      [15:0]    dist_cm   ,
    input      [15:0]    drop_px   ,
    input      [9:0]     fx        ,
    input      [9:0]     fy        ,

    output               txd
);

//localparam
localparam S_IDLE = 3'd0, S_CRC = 3'd1, S_REQ = 3'd2, S_WAIT = 3'd3;
localparam [5:0] LAST_IDX = 6'd33;      // 34 字节：0..33

//reg define
reg  [7:0]  b [0:31];        // 负载：byte0..byte31（含帧头与 seq）
reg  [15:0] crc16  ;
reg  [7:0]  crc_bi ;         // 0..239，逐位算 CRC
reg  [15:0] seq    ;
reg  [5:0]  idx    ;
reg  [2:0]  state  ;
reg  [7:0]  divcnt ;
reg  [7:0]  tx_byte;
reg         tx_start;

//wire define
wire        tx_busy, tx_done;

wire [7:0]  flags = {1'b1, far_small, moving, pred_ok, dist_ok,
                     disp_bin, adapt_ok, valid};

wire        tx_now = frame_tick && (divcnt == TX_DIV - 1);

//*****************************************************
//**                    main code
//*****************************************************

uart_tx #(.CLK_FREQ(CLK_FREQ), .BAUD(BAUD)) u_tx (
    .clk(clk), .rst_n(rst_n),
    .tx_start(tx_start), .tx_data(tx_byte),
    .tx_busy(tx_busy), .tx_done(tx_done), .txd(txd)
);

//-------------------------------------------------------
// 分频：每 TX_DIV 帧发一条
//-------------------------------------------------------
always @(posedge clk or negedge rst_n) begin
    if(!rst_n) divcnt <= 8'd0;
    else if(frame_tick) divcnt <= (divcnt == TX_DIV - 1) ? 8'd0 : (divcnt + 8'd1);
end

//-------------------------------------------------------
// 帧末锁存负载（只在 tx_now 那一拍更新 -> CRC 期间稳定）
//-------------------------------------------------------
always @(posedge clk or negedge rst_n) begin
    if(!rst_n) begin
        seq <= 16'd0;
        b[0]<=8'hA5; b[1]<=8'h5A; b[2]<=8'h00; b[3]<=8'h00; b[4]<=8'h00;
        b[5]<=8'h00; b[6]<=8'h00; b[7]<=8'h00; b[8]<=8'h00; b[9]<=8'h00;
        b[10]<=8'h00; b[11]<=8'h00; b[12]<=8'h00; b[13]<=8'h00; b[14]<=8'h00;
        b[15]<=8'h00; b[16]<=8'h00; b[17]<=8'h00; b[18]<=8'h00; b[19]<=8'h00;
        b[20]<=8'h00; b[21]<=8'h00; b[22]<=8'h00; b[23]<=8'h00; b[24]<=8'h00;
        b[25]<=8'h00; b[26]<=8'h00; b[27]<=8'h00; b[28]<=8'h00; b[29]<=8'h00;
        b[30]<=8'h00; b[31]<=8'h00;
    end
    //  只在「帧起始」那一拍锁存：tx_now 是电平型触发，一帧的发送时间（约 74,000 拍 @115200、
    //  34 字节）远大于 frame_tick 周期，不判 state 就会在发送途中重复锁存 ->
    //  传出去的 seq 与 CRC 对不上、接收端必然丢帧；真实工程里每帧变化的 cx/cy/w
    //  还会被中途更新，把两帧内容混成一帧。
    else if(tx_now && (state == S_IDLE)) begin
        b[0]  <= 8'hA5;
        b[1]  <= 8'h5A;
        b[2]  <= flags;
        b[3]  <= {6'b0, cx[9:8]};      b[4]  <= cx[7:0];
        b[5]  <= {6'b0, cy[9:8]};      b[6]  <= cy[7:0];
        b[7]  <= {6'b0, ax[9:8]};      b[8]  <= ax[7:0];
        b[9]  <= {6'b0, ay[9:8]};      b[10] <= ay[7:0];
        b[11] <= (bw > 11'd255) ? 8'd255 : bw[7:0];
        b[12] <= (area[31:7] > 32'd255) ? 8'd255 : area[14:7];
        b[13] <= fill_q8;
        b[14] <= {5'b0, blob_cnt};
        b[15] <= vx_q4[15:8];          b[16] <= vx_q4[7:0];
        b[17] <= vy_q4[15:8];          b[18] <= vy_q4[7:0];
        b[19] <= {6'b0, px[9:8]};      b[20] <= px[7:0];
        b[21] <= {6'b0, py[9:8]};      b[22] <= py[7:0];
        b[23] <= dist_cm[15:8];        b[24] <= dist_cm[7:0];
        b[25] <= drop_px[15:8];        b[26] <= drop_px[7:0];
        b[27] <= {6'b0, fx[9:8]};      b[28] <= fx[7:0];
        b[29] <= {6'b0, fy[9:8]};      b[30] <= fy[7:0];
        b[31] <= seq[7:0];
        seq   <= seq + 16'd1;
    end
end

//-------------------------------------------------------
// CRC-16/CCITT-FALSE 逐位串行
//   crc = 0xFFFF; 每位：msb = crc[15]^bit; crc<<=1; msb 则 crc ^= 0x1021
//   对 byte2..byte31（30 字节 = 240 位）计算，MSB 先。
//-------------------------------------------------------
wire [4:0]  crc_sel = crc_bi[7:3];              // 0..29
wire [2:0]  crc_bit = 7 - crc_bi[2:0];          // 7,6,...,0
wire [7:0]  crc_b   = b[crc_sel + 5'd2];        // -> byte2..byte31
wire        crc_msb = crc16[15] ^ crc_b[crc_bit];
wire [15:0] crc_nx  = {crc16[14:0], 1'b0} ^ (crc_msb ? 16'h1021 : 16'h0000);

//-------------------------------------------------------
// 发送状态机
//   IDLE -> CRC(240 拍) -> REQ/WAIT(34 字节)
//-------------------------------------------------------
wire [7:0] mux_byte = (idx == 6'd32) ? crc16[15:8] :
                      (idx == 6'd33) ? crc16[7:0]  : b[idx[4:0]];

always @(posedge clk or negedge rst_n) begin
    if(!rst_n) begin
        state    <= S_IDLE;
        idx      <= 6'd0;
        crc16    <= 16'hFFFF;
        crc_bi   <= 8'd0;
        tx_start <= 1'b0;
        tx_byte  <= 8'd0;
    end
    else begin
        tx_start <= 1'b0;
        case(state)
            S_IDLE: if(tx_now) begin
                        idx    <= 6'd0;
                        crc16  <= 16'hFFFF;
                        crc_bi <= 8'd0;
                        state  <= S_CRC;
                    end
            S_CRC:  begin
                        crc16 <= crc_nx;
                        if(crc_bi == 8'd239) state  <= S_REQ;
                        else                 crc_bi <= crc_bi + 8'd1;
                    end
            S_REQ:  if(!tx_busy) begin
                        tx_byte  <= mux_byte;
                        tx_start <= 1'b1;
                        state    <= S_WAIT;
                    end
            S_WAIT: if(tx_done) begin
                        if(idx == LAST_IDX) state <= S_IDLE;
                        else begin
                            idx   <= idx + 6'd1;
                            state <= S_REQ;
                        end
                    end
            default: state <= S_IDLE;
        endcase
    end
end

endmodule
