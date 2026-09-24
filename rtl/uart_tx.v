`timescale 1ns / 1ps
//****************************************************************************************//
// File name:           uart_tx
// Descriptions:        8N1 UART 发送（P1 的物理层）
//
//   纯 RTL，无 Xilinx IP：一个波特率计数器 + 一个位计数器。
//   tx_start 拉高一个 clk 就开始发送 tx_data（低位先出），发完 tx_done 给一个脉冲。
//   资源：约 60 LUT / 40 FF。
//****************************************************************************************//
module uart_tx #(
    parameter CLK_FREQ = 25_000_000,
    parameter BAUD     = 115200
)(
    input        clk     ,
    input        rst_n   ,
    input        tx_start,      // 一个 clk 的脉冲
    input  [7:0] tx_data ,
    output reg   tx_busy ,      // 正在发送
    output reg   tx_done ,      // 发完一个字节，一个 clk 脉冲
    output reg   txd            // 串行输出（空闲为高）
);

//localparam
localparam BAUD_CNT = CLK_FREQ / BAUD;

//reg define
reg  [15:0] bcnt  ;
reg  [3:0]  bidx  ;
reg  [9:0]  shreg ;      // {stop, data[7:0], start}

//wire define
wire bcnt_tick = (bcnt == BAUD_CNT - 1);

//*****************************************************
//**                    main code
//*****************************************************

always @(posedge clk or negedge rst_n) begin
    if(!rst_n) begin
        bcnt    <= 16'd0;
        bidx    <= 4'd0;
        shreg   <= 10'h3FF;      // 空闲：全 1
        txd     <= 1'b1;
        tx_busy <= 1'b0;
        tx_done <= 1'b0;
    end
    else begin
        tx_done <= 1'b0;

        if(!tx_busy) begin
            bcnt <= 16'd0;
            if(tx_start) begin
                shreg   <= {1'b1, tx_data, 1'b0};   // stop + data + start
                bidx    <= 4'd0;
                tx_busy <= 1'b1;
                txd     <= 1'b0;                    // 立刻拉低起始位
            end
        end
        else begin
            if(bcnt_tick) begin
                bcnt <= 16'd0;
                //  移位输出下一位
                shreg <= {1'b1, shreg[9:1]};
                txd   <= shreg[1];
                if(bidx == 4'd9) begin
                    tx_busy <= 1'b0;
                    tx_done <= 1'b1;
                    txd     <= 1'b1;
                end
                else
                    bidx <= bidx + 4'd1;
            end
            else
                bcnt <= bcnt + 16'd1;
        end
    end
end

endmodule
