//****************************************Copyright (c)***********************************//
// File name:           line_buffer
// Descriptions:        單行像素緩衝（一行深度），供形態學 / 延遲線級聯使用
//
//   【為什麼要獨立成一個模組】要讓 Vivado 穩定推斷出分散式 RAM（LUTRAM），
//   最保險的寫法是「同步寫 + 連續賦值讀（assign）」這個標準模板。
//   若把讀取寫在 always @(*) 或和寫入放在不同 always 區塊，
//   Vivado 常常會退化成用正反器 + 大 mux 來實作，
//   800 深的緩衝就會吃掉上千個 LUT 與 FF（實測：整個管線曾爆到 75% LUT）。
//
//   讀寫位址相同時：讀取（組合）看到的是「舊值」，因為寫入在下一個時脈才生效，
//   這正好是行緩衝級聯需要的行為。
//----------------------------------------------------------------------------------------
//****************************************************************************************//
`timescale 1ns / 1ps

module line_buffer #(
    parameter DW    = 1  ,   // 資料位寬（二值圖 = 1，RGB565 = 16）
    parameter WIDTH = 800,   // 深度 = 一行像素數
    parameter AW    = 10     // 位址位寬
)(
    input                clk  ,   // 時鐘
    input                we   ,   // 寫入致能
    input      [AW-1:0]  waddr,   // 寫入位址
    input      [DW-1:0]  din  ,   // 寫入資料
    input      [AW-1:0]  raddr,   // 讀取位址（非同步）
    output     [DW-1:0]  dout     // 讀出資料
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
