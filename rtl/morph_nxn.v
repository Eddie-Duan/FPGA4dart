//****************************************Copyright (c)***********************************//
// File name:           morph_nxn
// Descriptions:        N x N 形態學（膨脹 / 腐蝕），資料為 1bit 二值圖
//
//   窗口對齊方式：以「當前像素」為窗口右下角
//        window(x, y) = { din(x-N+1 .. x,  y-N+1 .. y) }
//   也就是輸出的空間位置比輸入往右下偏移 (N-1)/2，兩級串接共偏移 N-1，
//   上層用 video_delay 把原圖也延遲 N-1 行/像素，兩者在螢幕上就對齊了。
//
//   行緩衝用 line_buffer（分散式 RAM 標準模板）級聯而成：
//   垂直移位：lb_out[0] 存上一行、lb_out[1] 存上上行 ... 以此類推
//   水平移位：每行各一組 hsr 移位暫存器（只在 de 有效時推進，行首清 0，
//             避免跨行殘留造成左邊界錯誤）
//----------------------------------------------------------------------------------------
//****************************************************************************************//
`timescale 1ns / 1ps

module morph_nxn #(
    parameter N      = 9    ,   // 窗口大小（奇數，dart 用 9）
    parameter WIDTH  = 800  ,   // 一行像素數（行緩衝深度）
    parameter AW     = 10   ,   // x 位寬
    parameter DILATE = 1        // 1 = 膨脹(OR)，0 = 腐蝕(AND)
)(
    input               clk   ,  // 時鐘
    input               rst_n ,  // 復位
    input               de    ,  // 像素有效
    input      [AW-1:0] x     ,  // 當前像素 x（0 起算，需 < WIDTH）
    input               din   ,  // 輸入二值
    output              dout     // 輸出二值（組合邏輯，與 din 同拍同一 x）
);

//localparam define
localparam NL = N-1;             // 需要的行緩衝條數

//reg define
reg [N-2:0] hsr [0:N-1];         // 每行的水平窗口

//wire define
wire [NL-1:0] lb_out ;           // 各行緩衝輸出（lb_out[0] = 上一行）
wire [NL-1:0] lb_din ;           // 各行緩衝輸入（級聯）
wire [N-1:0]  vtap           ;   // 垂直抽頭：vtap[0] = 當前行
assign vtap = {lb_out, din};     // {lb_out[0]=上一行, ..., din=當前行}

//reg/other define
reg          tree_or  ;
reg          tree_and ;
integer      k ;
genvar       i ;

//*****************************************************
//**                    main code
//*****************************************************

//-------------------------------------------------------
// 行緩衝級聯：第 0 條吃 din，第 k 條吃第 k-1 條的輸出
//-------------------------------------------------------
assign lb_din = {lb_out[NL-2:0], din};

generate
    for(i=0; i<NL; i=i+1) begin : gen_line_buf
        line_buffer #(
            .DW    (1    ),
            .WIDTH (WIDTH),
            .AW    (AW   )
        ) u_line_buffer (
            .clk   (clk           ),
            .we    (de && (x < WIDTH)),
            .waddr (x             ),
            .din   (lb_din[i]     ),
            .raddr (x             ),
            .dout  (lb_out[i]     )
        );
    end
endgenerate

//-------------------------------------------------------
// 水平移位（行首清空）
//-------------------------------------------------------
always @(posedge clk or negedge rst_n) begin
    if(!rst_n) begin
        for(k=0; k<N; k=k+1)
            hsr[k] <= {(N-1){1'b0}};
    end
    else begin
        for(k=0; k<N; k=k+1) begin
            if(!de)
                hsr[k] <= {(N-1){1'b0}};    // 行首清空
            else
                hsr[k] <= {hsr[k][N-3:0], vtap[k]};
        end
    end
end

//-------------------------------------------------------
// N x N 窗口運算
//   hsr[k] 存放該行前 N-1 個時鐘的像素（hsr[k][0] 是 1 拍前）
//   {hsr[k], vtap[k]} 即為該行連續 N 個像素
//-------------------------------------------------------
always @(*) begin
    tree_or  = 1'b0;
    tree_and = 1'b1;
    for(k=0; k<N; k=k+1) begin
        tree_or  = tree_or  | (|{hsr[k], vtap[k]});
        tree_and = tree_and & (&{hsr[k], vtap[k]});
    end
end

assign dout = DILATE ? tree_or : tree_and;

endmodule
