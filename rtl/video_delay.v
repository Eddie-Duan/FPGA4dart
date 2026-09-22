//****************************************Copyright (c)***********************************//
// File name:           video_delay
// Descriptions:        像素串流延遲器（延遲 LINES 行 + PIXELS 像素）
//
//   用途：形態學兩級（膨脹+腐蝕）的窗口是「右下角對齊」，
//         所以二值圖在螢幕上會整體往右下偏移 N-1（N 為窗口大小）。
//         把原圖也延遲同樣的行數與像素數，原圖與標記就會對齊。
//
//   行緩衝用 line_buffer（分散式 RAM 標準模板）級聯而成，
//   讀寫位址都是當前列，讀取看到舊值 = 延遲一整行。
//   PIXELS 用一般移位暫存器（行首清 0，避免跨行殘留）。
//----------------------------------------------------------------------------------------
//****************************************************************************************//
`timescale 1ns / 1ps

module video_delay #(
    parameter DW     = 16  ,   // 資料位寬
    parameter WIDTH  = 800 ,   // 一行像素數
    parameter LINES  = 8   ,   // 延遲行數
    parameter PIXELS = 8   ,   // 延遲像素數
    parameter AW     = 10      // x 位寬
)(
    input                clk   ,  // 時鐘
    input                rst_n ,  // 復位
    input                de    ,  // 像素有效
    input      [AW-1:0]  x     ,  // 當前像素 x
    input      [DW-1:0]  din   ,  // 輸入像素
    output     [DW-1:0]  dout     // 延遲後像素（與 din 同拍輸出）
);

//wire define
wire [LINES*DW-1:0] lb_out ;   // 各行緩衝輸出
wire [LINES*DW-1:0] lb_din ;   // 各行緩衝輸入（級聯）
wire [DW-1:0]       vert_d ;   // 延遲 LINES 行後的像素

//reg define
reg  [DW-1:0] sr [0:PIXELS-1];   // 水平移位
integer k;
genvar  i;

//*****************************************************
//**                    main code
//*****************************************************

//-------------------------------------------------------
// 行緩衝級聯：第 0 條吃 din，第 k 條吃第 k-1 條的輸出
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
