//****************************************Copyright (c)***********************************//
// File name:           video_delay
// Descriptions:        像素串流延迟器（延迟 LINES 行 + PIXELS 像素）
//
//   用途：形态学两级（膨胀+腐蚀）的窗口是“右下角对齐”，
//         所以二值图在屏幕上会整体往右下偏移 N-1（N 为窗口大小）。
//         把原图也延迟同样的行数与像素数，原图与标记就会对齐。
//
//   行缓冲用 line_buffer（分散式 RAM 标准模板）级联而成，
//   读写地址都是当前列，读取看到旧值 = 延迟一整行。
//   PIXELS 用一般移位寄存器（行首清 0，避免跨行残留）。
//----------------------------------------------------------------------------------------
//****************************************************************************************//
`timescale 1ns / 1ps

module video_delay #(
    parameter DW     = 16  ,   // 数据位宽
    parameter WIDTH  = 800 ,   // 一行像素数
    parameter LINES  = 8   ,   // 延迟行数
    parameter PIXELS = 8   ,   // 延迟像素数
    parameter AW     = 10      // x 位宽
)(
    input                clk   ,  // 时钟
    input                rst_n ,  // 复位
    input                de    ,  // 像素有效
    input      [AW-1:0]  x     ,  // 当前像素 x
    input      [DW-1:0]  din   ,  // 输入像素
    output     [DW-1:0]  dout     // 延迟后像素（与 din 同拍输出）
);

//wire define
wire [LINES*DW-1:0] lb_out ;   // 各行缓冲输出
wire [LINES*DW-1:0] lb_din ;   // 各行缓冲输入（级联）
wire [DW-1:0]       vert_d ;   // 延迟 LINES 行后的像素

//reg define
reg  [DW-1:0] sr [0:PIXELS-1];   // 水平移位
integer k;
genvar  i;

//*****************************************************
//**                    main code
//*****************************************************

//-------------------------------------------------------
// 行缓冲级联：第 0 条吃 din，第 k 条吃第 k-1 条的输出
//-------------------------------------------------------
assign lb_din = {lb_out[(LINES-1)*DW-1:0], din};

generate
    for(i=0; i<LINES; i=i+1) begin : gen_line_buf
        line_buffer #(
            .DW    (DW   ),
            .WIDTH (WIDTH),
            .AW    (AW   )
        ) u_line_buffer (
            .clk   (clk              ),
            .we    (de && (x < WIDTH)),
            .waddr (x                ),
            .din   (lb_din[i*DW +: DW]),
            .raddr (x                ),
            .dout  (lb_out[i*DW +: DW])
        );
    end
endgenerate

assign vert_d = lb_out[(LINES-1)*DW +: DW];   // LINES 行前的像素

//-------------------------------------------------------
// 水平移位（行首清空）
//-------------------------------------------------------
always @(posedge clk or negedge rst_n) begin
    if(!rst_n) begin
        for(k=0; k<PIXELS; k=k+1)
            sr[k] <= {DW{1'b0}};
    end
    else if(!de) begin
        for(k=0; k<PIXELS; k=k+1)
            sr[k] <= {DW{1'b0}};
    end
    else begin
        sr[0] <= vert_d;
        for(k=1; k<PIXELS; k=k+1)
            sr[k] <= sr[k-1];
    end
end

assign dout = sr[PIXELS-1];

endmodule
