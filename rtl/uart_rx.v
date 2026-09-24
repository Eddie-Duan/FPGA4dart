`timescale 1ns / 1ps
//****************************************************************************************//
// File name:           uart_rx
// Descriptions:        8N1 UART 接收（P2 的物理层）
//
//   纯 RTL，无 Xilinx IP。rxd 先过两级同步器去掉亚稳态，再检测起始位下降沿，
//   然后在每个位的**中点**采样（比等边沿稳）。收完 8 位数据 + 停止位后 rx_done 给脉冲。
//   资源：约 80 LUT / 40 FF。
//****************************************************************************************//
module uart_rx #(
    parameter CLK_FREQ = 25_000_000,
    parameter BAUD     = 115200
)(
    input        clk     ,
    input        rst_n   ,
    input        rxd     ,
    output reg [7:0] rx_data,
    output reg   rx_done        // 收完一个字节，一个 clk 脉冲
);

//localparam
localparam BAUD_CNT = CLK_FREQ / BAUD;
localparam HALF     = BAUD_CNT / 2;

//reg define
reg  [1:0]  rxd_sync ;
reg  [15:0] bcnt     ;
reg  [3:0]  bidx     ;
reg  [7:0]  shreg    ;
reg         rx_busy  ;

//wire define
wire rx_in     = rxd_sync[1];
wire bcnt_tick = (bcnt == BAUD_CNT - 1);

//*****************************************************
//**                    main code
//*****************************************************

always @(posedge clk or negedge rst_n) begin
    if(!rst_n) rxd_sync <= 2'b11;
    else       rxd_sync <= {rxd_sync[0], rxd};
end

always @(posedge clk or negedge rst_n) begin
    if(!rst_n) begin
        bcnt    <= 16'd0;
        bidx    <= 4'd0;
        shreg   <= 8'd0;
        rx_busy <= 1'b0;
        rx_data <= 8'd0;
        rx_done <= 1'b0;
    end
    else begin
        rx_done <= 1'b0;

        if(!rx_busy) begin
            //  等起始位下降沿（rx_in 已经过同步，直接当电平用）
            if(!rx_in) begin
                rx_busy <= 1'b1;
                bcnt    <= 16'd0;
                bidx    <= 4'd0;
            end
        end
        else begin
            if(bidx == 4'd0) begin
                //  跳过半个位宽，对齐到起始位中点
                if(bcnt == HALF - 1) begin
                    bcnt <= 16'd0;
                    bidx <= 4'd1;
                end
                else
                    bcnt <= bcnt + 16'd1;
            end
            else if(bcnt_tick) begin
                bcnt <= 16'd0;
                if(bidx <= 4'd8) begin
                    shreg <= {rx_in, shreg[7:1]};
                    bidx  <= bidx + 4'd1;
                end
                else begin
                    //  bidx == 9：采样停止位，结束
                    rx_busy <= 1'b0;
                    rx_data <= shreg;
                    rx_done <= 1'b1;
                end
            end
            else
                bcnt <= bcnt + 16'd1;
        end
    end
end

endmodule
