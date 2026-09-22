//****************************************Copyright (c)***********************************//
// File name:           morph_nxn
// Descriptions:        N x N 形态学（膨胀 / 腐蚀），数据为 1bit 二值图
//
//   窗口对齐方式：以“当前像素”为窗口右下角
//        window(x, y) = { din(x-N+1 .. x,  y-N+1 .. y) }
//   也就是输出的空间位置比输入往右下偏移 (N-1)/2，两级串接共偏移 N-1，
//   上层用 video_delay 把原图也延迟 N-1 行/像素，两者在屏幕上就对齐了。
//
//   行缓冲用 line_buffer（分散式 RAM 标准模板）级联而成：
//   垂直移位：lb_out[0] 存上一行、lb_out[1] 存上上行 ... 以此类推
//   水平移位：每行各一组 hsr 移位寄存器（只在 de 有效时推进，行首清 0，
//             避免跨行残留造成左边界错误）
//----------------------------------------------------------------------------------------
//****************************************************************************************//
`timescale 1ns / 1ps

module morph_nxn #(
    parameter N      = 9    ,   // 窗口大小（奇数，dart 用 9）
    parameter WIDTH  = 800  ,   // 一行像素数（行缓冲深度）
    parameter AW     = 10   ,   // x 位宽
    parameter DILATE = 1        // 1 = 膨胀(OR)，0 = 腐蚀(AND)
)(
    input               clk   ,  // 时钟
    input               rst_n ,  // 复位
    input               de    ,  // 像素有效
    input      [AW-1:0] x     ,  // 当前像素 x（0 起算，需 < WIDTH）
    input               din   ,  // 输入二值
    output              dout     // 输出二值（组合逻辑，与 din 同拍同一 x）
);

//localparam define
localparam NL = N-1;             // 需要的行缓冲条数

//reg define
reg [N-2:0] hsr [0:N-1];         // 每行的水平窗口

//wire define
wire [NL-1:0] lb_out ;           // 各行缓冲输出（lb_out[0] = 上一行）
wire [NL-1:0] lb_din ;           // 各行缓冲输入（级联）
wire [N-1:0]  vtap           ;   // 垂直抽头：vtap[0] = 当前行
assign vtap = {lb_out, din};     // {lb_out[0]=上一行, ..., din=当前行}

//reg/other define
reg          tree_or  ;
reg          tree_and ;
integer      k ;
genvar       i ;

//*****************************************************
//**                    main code
//*****************************************************

//-------------------------------------------------------
// 行缓冲级联：第 0 条吃 din，第 k 条吃第 k-1 条的输出
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
// N x N 窗口运算
//   hsr[k] 存放该行前 N-1 个时钟的像素（hsr[k][0] 是 1 拍前）
//   {hsr[k], vtap[k]} 即为该行连续 N 个像素
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
