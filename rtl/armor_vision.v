//****************************************Copyright (c)***********************************//
// File name:           armor_vision
// Descriptions:        視覺管線頂層（紅/藍裝甲板辨識 + 邊界框 + 中心十字）
//
//   資料來源：DDR3 讀出的像素串流（rddata / rdata_req / rd_vsync）
//   資料去向：送到 lcd_rgb_top 顯示
//
//   管線：
//     (1) 顏色分割（紅 or 藍，按鍵切換）           color_seg
//     (2) 形態學閉運算 = 膨脹 -> 腐蝕             morph_nxn x2
//     (3) 原圖延遲 N-1 行/像素（與形態學位移對齊） video_delay
//     (4) 列投影 + 燈條配對 + 邊界框              proj_bond
//     (5) 疊加邊界框 + 中心十字                   overlay_box
//     (6) 顯示合成（原圖變暗+標記 / 純二值）      本檔
//
//   【輸入對齊】rddata 比 rdata_req 慢一拍（ddr3_fifo_ctrl 的 rddata 是寄存器輸出），
//   所以本模組先把 (data_in, de, x) 打一拍，讓資料與座標嚴格對齊，
//   後級所有模組都在這一拍後的時序上工作。
//----------------------------------------------------------------------------------------
//****************************************************************************************//
`timescale 1ns / 1ps

module armor_vision #(
    parameter IMG_W       = 800,          // 影像寬度（= LCD 寬度，1:1 不需縮放）
    parameter AW          = 10 ,          // 座標位寬
    parameter MORPH_N     = 9  ,          // 形態學窗口大小（奇數；dart 用 9，可改 5/3）
    parameter CLK_FREQ    = 25_000_000,   // 像素時鐘頻率（4.3 吋 800x480 -> 25MHz）
    parameter LUM_MIN_SUM = 150,          // 亮度下限（見 color_seg）
    parameter HIST_TH     = 48 ,          // 欄投影門檻（見 proj_bond）
    parameter MIN_W       = 6  ,          // 燈條最小寬度
    parameter MAX_W       = 240,          // 燈條最大寬度
    parameter MIN_GAP     = 10 ,          // 兩燈條最小間距
    parameter MAX_GAP     = 520,          // 兩燈條最大間距
    parameter BOX_THICK   = 3             // 框線寬度
)(
    input                clk        ,   // 像素時鐘（lcd_clk）
    input                rst_n      ,   // 復位
    input                vsync      ,   // 幀起始脈衝（rd_vsync）
    input                de         ,   // 像素有效（rdata_req）
    input      [15:0]    data_in    ,   // 像素資料（rddata）
    input      [3:0]     key        ,   // 按鍵（低電平有效）
    output     [15:0]    data_out   ,   // 處理後像素（送 LCD）
    output     [3:0]     led        ,   // LED 指示（低電平點亮）
    // 偵測結果（觀測/除錯用）
    output               bond_valid ,
    output     [AW-1:0]  center_x   ,
    output     [AW-1:0]  center_y
);

//localparam define
localparam SGUARD  = MORPH_N - 1;       // 形態學造成的空間位移
localparam Y_GUARD = 2*SGUARD;          // 頂端無效行數（兩級形態學）

//reg define
reg  [AW-1:0] x_cnt  ;   // 輸入端 x 計數
reg  [AW-1:0] y_cnt  ;   // 對齊後的 y 計數（有效行由 1 起算）
reg           de_seen;   // 本幀是否已經出現過有效像素
reg           de_d    ;  // de 延遲一拍（找行尾）
reg           de_v   ;   // 對齊後的有效訊號
reg  [AW-1:0] x_v    ;   // 對齊後的 x
reg  [15:0]   data_v ;   // 對齊後的像素

//wire define
wire          mode     ;   // 0 = 紅，1 = 藍
wire [7:0]    thresh   ;   // 顏色門檻
wire          disp_bin ;   // 顯示模式
wire          seg_mask ;   // 顏色分割結果
wire          dil_mask ;   // 膨脹結果
wire          ero_mask ;   // 腐蝕結果（= 閉運算結果）
wire [15:0]   img_d    ;   // 與二值圖對齊的原圖
wire [AW-1:0] bl, br, bt, bb;
wire          draw     ;

//*****************************************************
//**                    main code
//*****************************************************

//-------------------------------------------------------
// 輸入對齊：把 (data_in, de) 打一拍，並用打拍後的 de 產生座標
//   x_v : 一行內 0 ~ IMG_W-1
//   y_v : 有效行由 1 起算（只在有資料的行計數，所以不受垂直消隱行數影響）
//-------------------------------------------------------
always @(posedge clk or negedge rst_n) begin
    if(!rst_n) begin
        x_cnt   <= {AW{1'b0}};
        y_cnt   <= {AW{1'b0}};
        de_seen <= 1'b0;
        de_d    <= 1'b0;
        de_v    <= 1'b0;
        x_v     <= {AW{1'b0}};
        data_v  <= 16'd0;
    end
    else begin
        // 輸入端 x 計數（以 rdata_req 為準）
        if(!de)
            x_cnt <= {AW{1'b0}};
        else
            x_cnt <= x_cnt + 1'b1;

        // 打一拍對齊 fifo 輸出
        de_v   <= de;
        data_v <= data_in;
        x_v    <= x_cnt;      // 與 data_v 同一個像素

        // y 計數：本幀第一個有效像素所在的行 = 第 1 行，之後在行尾進位
        de_d <= de_v;
        if(vsync) begin
            y_cnt   <= {AW{1'b0}};
            de_seen <= 1'b0;
        end
        else if(de_v && !de_seen) begin
            y_cnt   <= {{(AW-1){1'b0}}, 1'b1};
            de_seen <= 1'b1;
        end
        else if(de_d && !de_v) begin
            y_cnt <= y_cnt + 1'b1;
        end
    end
end

//-------------------------------------------------------
// (1) 顏色分割 / 按鍵參數
//-------------------------------------------------------
vision_cfg #(
    .CLK_FREQ (CLK_FREQ)
) u_vision_cfg (
    .clk      (clk     ),
    .rst_n    (rst_n   ),
    .key      (key     ),
    .mode     (mode    ),
    .thresh   (thresh  ),
    .disp_bin (disp_bin)
);

color_seg #(
    .LUM_MIN_SUM (LUM_MIN_SUM)
) u_color_seg (
    .rgb565 (data_v   ),
    .mode   (mode     ),
    .thresh (thresh   ),
    .mask   (seg_mask )
);

//-------------------------------------------------------
// (2) 形態學：膨脹 -> 腐蝕 = 閉運算（填補燈條內小空洞、把小斷點連起來）
//-------------------------------------------------------
morph_nxn #(
    .N      (MORPH_N),
    .WIDTH  (IMG_W  ),
    .AW     (AW     ),
    .DILATE (1      )
) u_dilate (
    .clk   (clk      ),
    .rst_n (rst_n    ),
    .de    (de_v     ),
    .x     (x_v      ),
    .din   (seg_mask ),
    .dout  (dil_mask )
);

morph_nxn #(
    .N      (MORPH_N),
    .WIDTH  (IMG_W  ),
    .AW     (AW     ),
    .DILATE (0      )
) u_erode (
    .clk   (clk      ),
    .rst_n (rst_n    ),
    .de    (de_v     ),
    .x     (x_v      ),
    .din   (dil_mask ),
    .dout  (ero_mask )
);

// 頂端 2*(N-1) 行行緩衝還沒填滿（內容是上一幀的殘留），直接視為 0
wire mask_d = ero_mask & (y_cnt > Y_GUARD);

//-------------------------------------------------------
// (3) 原圖延遲：形態學讓二值圖往右下偏移 N-1，原圖也延遲 N-1 行/像素
//-------------------------------------------------------
video_delay #(
    .DW     (16     ),
    .WIDTH  (IMG_W  ),
    .LINES  (SGUARD ),
    .PIXELS (SGUARD ),
    .AW     (AW     )
) u_video_delay (
    .clk   (clk    ),
    .rst_n (rst_n  ),
    .de    (de_v   ),
    .x     (x_v    ),
    .din   (data_v ),
    .dout  (img_d  )
);

//-------------------------------------------------------
// (4) 列投影 + 燈條配對 + 邊界框
//-------------------------------------------------------
proj_bond #(
    .WIDTH   (IMG_W   ),
    .AW      (AW      ),
    .HIST_TH (HIST_TH ),
    .MIN_W   (MIN_W   ),
    .MAX_W   (MAX_W   ),
    .MIN_GAP (MIN_GAP ),
    .MAX_GAP (MAX_GAP ),
    .Y_GUARD (Y_GUARD )
) u_proj_bond (
    .clk        (clk        ),
    .rst_n      (rst_n      ),
    .vsync      (vsync      ),
    .de         (de_v       ),
    .x          (x_v        ),
    .y          (y_cnt      ),
    .mask       (mask_d     ),
    .bond_valid (bond_valid ),
    .bond_l     (bl         ),
    .bond_r     (br         ),
    .bond_t     (bt         ),
    .bond_b     (bb         ),
    .center_x   (center_x   ),
    .center_y   (center_y   )
);

//-------------------------------------------------------
// (5) 疊加邊界框 + 中心十字
//-------------------------------------------------------
overlay_box #(
    .AW    (AW        ),
    .THICK (BOX_THICK )
) u_overlay_box (
    .valid (bond_valid),
    .x     (x_v       ),
    .y     (y_cnt     ),
    .bl    (bl        ),
    .br    (br        ),
    .bt    (bt        ),
    .bb    (bb        ),
    .cx    (center_x  ),
    .cy    (center_y  ),
    .draw  (draw      )
);

//-------------------------------------------------------
// (6) 顯示合成
//   模式 0：原圖亮度減半 + 命中的燈條保持原色 + 綠色框/十字
//   模式 1：純二值圖（白 = 命中）+ 綠色框/十字
//-------------------------------------------------------
wire [15:0] dim_pix = {1'b0, img_d[15:12],    // R5 減半
                       1'b0, img_d[10:6],     // G6 減半
                       1'b0, img_d[4:1]};     // B5 減半

wire [15:0] disp_pix = disp_bin ? (mask_d ? 16'hFFFF : 16'h0000)
                                : (mask_d ? img_d  : dim_pix);

assign data_out = draw ? 16'h07E0 : disp_pix;   // RGB565 綠色

//-------------------------------------------------------
// LED 指示（板上低電平點亮）
//   led[0] : 紅色模式    led[1] : 藍色模式
//   led[2] : 偵測到裝甲板 led[3] : 心跳
//-------------------------------------------------------
reg [23:0] hb_cnt;
always @(posedge clk or negedge rst_n) begin
    if(!rst_n) hb_cnt <= 24'd0;
    else       hb_cnt <= hb_cnt + 1'b1;
end

wire red_mode  = ~mode;
wire blue_mode =  mode;

assign led[0] = ~red_mode;
assign led[1] = ~blue_mode;
assign led[2] = ~bond_valid;
assign led[3] = ~hb_cnt[23];

endmodule
