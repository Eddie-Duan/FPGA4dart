//****************************************Copyright (c)***********************************//
// File name:           line_buffer
// Descriptions:        单行像素缓冲（一行深度），供形态学 / 延迟线级联使用
//
//   【为什么要独立成一个模块】要让 Vivado 稳定推断出分散式 RAM（LUTRAM），
//   最保险的写法是“同步写 + 连续赋值读（assign）”这个标准模板。
//   若把读取写在 always @(*) 或和写入放在不同 always 区块，
//   Vivado 常常会退化成用正反器 + 大 mux 来实现，
//   800 深的缓冲就会吃掉上千个 LUT 与 FF（实测：整个管线曾爆到 75% LUT）。
//
//   读写地址相同时：读取（组合）看到的是“旧值”，因为写入在下一个时钟才生效，
//   这正好是行缓冲级联需要的行为。
//----------------------------------------------------------------------------------------
//****************************************************************************************//
`timescale 1ns / 1ps

module line_buffer #(
    parameter DW    = 1  ,   // 数据位宽（二值图 = 1，RGB565 = 16）
    parameter WIDTH = 800,   // 深度 = 一行像素数
    parameter AW    = 10     // 地址位宽
)(
    input                clk  ,   // 时钟
    input                we   ,   // 写入使能
    input      [AW-1:0]  waddr,   // 写入地址
    input      [DW-1:0]  din  ,   // 写入数据
    input      [AW-1:0]  raddr,   // 读取地址（异步）
    output     [DW-1:0]  dout     // 读出数据
);

//reg define
(* ram_style = "distributed" *) reg [DW-1:0] mem [0:WIDTH-1];

//*****************************************************
//**                    main code
//*****************************************************

always @(posedge clk) begin
    if(we)
        mem[waddr] <= din;
end

assign dout = mem[raddr];

endmodule
