//****************************************Copyright (c)***********************************//
// File name:           proj_bond
// Descriptions:        列投影 + 燈條配對 + 邊界框（用投影法取代連通域標記 CCL）
//
//   原理（燈條是「細長的垂直亮條」，用投影法比 CCL 便宜 5 倍也好除錯）：
//     1. 整幀逐列累加：hist[x] = 第 x 列被判定為亮像素的個數
//     2. 幀結束後掃描 hist，找連續亮欄區間（run），取最寬的兩個當候選燈條
//     3. X 範圍確定後，在「下一幀」用這兩個 X 範圍累加 Y 的上下界
//     4. 兩燈條寬度相近、間距合理 → 認定為裝甲板，算出邊界框與中心
//
//   【時間關係】掃描與出框都發生在垂直消隱期（vsync 脈衝之後），
//   約 802 個時鐘就結束，離下一個有效顯示行還有約 8000 個時鐘，時間充裕。
//
//   【一個延遲】Y 的上下界是用「上一幀算出的 X 範圍」累加的，
//   因此邊界框會慢一幀才顯示，對靜態靶紙完全沒有影響。
//----------------------------------------------------------------------------------------
//****************************************************************************************//
`timescale 1ns / 1ps

module proj_bond #(
    parameter WIDTH     = 800 ,   // 影像寬度（hist 深度）
    parameter AW        = 10  ,   // 座標位寬
    parameter HW        = 10  ,   // hist 位寬（>= log2(影像高度)）
    parameter HIST_TH   = 48  ,   // 欄投影門檻：一列亮像素超過此值才算「亮欄」
    parameter MIN_W     = 6   ,   // 燈條最小寬度
    parameter MAX_W     = 240 ,   // 燈條最大寬度（超過視為大面積色塊，丟棄）
    parameter MERGE_GAP = 4   ,   // 小於此間隙的兩個 run 視為同一根燈條
    parameter MIN_GAP   = 10  ,   // 兩燈條最小間距
    parameter MAX_GAP   = 520 ,   // 兩燈條最大間距
    parameter Y_GUARD   = 16      // 忽略畫面頂端無效行（行緩衝未填滿）
)(
    input                clk       ,   // 時鐘
    input                rst_n     ,   // 復位
    input                vsync     ,   // 幀起始脈衝（1 拍）
    input                de        ,   // 像素有效
    input      [AW-1:0]  x         ,   // 當前像素 x
    input      [AW-1:0]  y         ,   // 當前像素 y（有效行由 1 起算）
    input                mask      ,   // 最終二值圖
    // 偵測結果（螢幕座標，供 overlay 畫框）
    output reg           bond_valid,   // 邊界框有效
    output reg [AW-1:0]  bond_l    ,
    output reg [AW-1:0]  bond_r    ,
    output reg [AW-1:0]  bond_t    ,
    output reg [AW-1:0]  bond_b    ,
    output reg [AW-1:0]  center_x  ,
    output reg [AW-1:0]  center_y
);

//localparam define
localparam S_IDLE  = 2'd0;
localparam S_SCAN  = 2'd1;
localparam S_LATCH = 2'd2;
localparam MAXVAL  = {AW{1'b1}};

//reg define
(* ram_style = "distributed" *) reg [HW-1:0] hist [0:WIDTH-1];  // 欄投影直方圖

reg  [1:0]  state     ;   // 主狀態
reg  [AW:0] scan_cnt  ;   // 掃描計數（多跑一拍把最後一個 run 收尾）

reg         run_act   ;   // 目前正在一個 run 內
reg  [AW-1:0] run_st  ;   // run 起點
reg  [AW-1:0] run_last;   // run 最後一個亮欄
reg  [AW-1:0] gap_cnt ;   // run 內部的空隙計數

reg  [AW-1:0] w1, st1 ;   // 候選一（最寬）
reg  [AW-1:0] w2, st2 ;   // 候選二
reg         en1, en2  ;

reg  [AW-1:0] x1t_min, x1t_max ;   // 追蹤用 X 範圍（左燈條，來自上一幀）
reg  [AW-1:0] x2t_min, x2t_max ;   // 追蹤用 X 範圍（右燈條）
reg         pair_ok_trk        ;   // 追蹤用的 X 範圍是否為合法配對

reg  [AW-1:0] y1_min_acc, y1_max_acc ;   // 本幀累積的 Y 上下界（左燈條）
reg  [AW-1:0] y2_min_acc, y2_max_acc ;   // 本幀累積的 Y 上下界（右燈條）
reg         y1_seen, y2_seen         ;   // 是否看到過

//wire define
wire          scanning = (state == S_SCAN);
wire [AW-1:0] raddr    = scanning ? scan_cnt[AW-1:0] : x;
wire [HW-1:0] hval     = hist[raddr];                       // 非同步讀（標準 RAM 模板）
wire          lit      = scanning && (scan_cnt < WIDTH) && (hval >= HIST_TH);

// 單一寫埠：掃描時清零、掃描外累加（Vivado 要單一寫埠才會推斷 RAM）
wire          hist_we    = scanning ? (scan_cnt < WIDTH)
                                    : (de && mask && (y > Y_GUARD) && (x < WIDTH));
wire [AW-1:0] hist_waddr = scanning ? scan_cnt[AW-1:0] : x;
wire [HW-1:0] hist_wdata = scanning ? {HW{1'b0}} : (hval + 1'b1);

wire [AW-1:0] run_w   = run_last - run_st + 1'b1;           // 目前 run 的寬度
wire          run_fin = run_act && (!lit) &&
                        ((scan_cnt >= WIDTH) || (gap_cnt >= MERGE_GAP));

// 兩個候選依 x 位置排出左右
wire [AW-1:0] L_st = (st1 <= st2) ? st1 : st2;
wire [AW-1:0] L_w  = (st1 <= st2) ? w1  : w2 ;
wire [AW-1:0] R_st = (st1 <= st2) ? st2 : st1;
wire [AW-1:0] R_w  = (st1 <= st2) ? w2  : w1 ;
wire [AW:0]   gap  = {1'b0,R_st} - {1'b0,L_st} - {1'b0,L_w};  // 兩燈條間距（可能下溢）

wire pair_ok = en1 & en2
             & (gap >= MIN_GAP) & (gap <= MAX_GAP)
             & ((L_w << 1) >= R_w) & ((R_w << 1) >= L_w);      // 寬度相差不超過兩倍

wire [AW-1:0] yy_top = (y1_min_acc < y2_min_acc) ? y1_min_acc : y2_min_acc;
wire [AW-1:0] yy_bot = (y1_max_acc > y2_max_acc) ? y1_max_acc : y2_max_acc;

//*****************************************************
//**                    main code
//*****************************************************

//-------------------------------------------------------
// 直方圖：單一寫埠（掃描時清零 / 掃描外累加）
//-------------------------------------------------------
always @(posedge clk) begin
    if(hist_we)
        hist[hist_waddr] <= hist_wdata;
end

//-------------------------------------------------------
// 主狀態機
//-------------------------------------------------------
always @(posedge clk or negedge rst_n) begin
    if(!rst_n) begin
        state      <= S_IDLE;
        scan_cnt   <= {(AW+1){1'b0}};
        run_act    <= 1'b0;
        run_st     <= {AW{1'b0}};
        run_last   <= {AW{1'b0}};
        gap_cnt    <= {AW{1'b0}};
        w1         <= {AW{1'b0}};
        st1        <= {AW{1'b0}};
        w2         <= {AW{1'b0}};
        st2        <= {AW{1'b0}};
        en1        <= 1'b0;
        en2        <= 1'b0;
        x1t_min    <= {AW{1'b0}};
        x1t_max    <= {AW{1'b0}};
        x2t_min    <= {AW{1'b0}};
        x2t_max    <= {AW{1'b0}};
        pair_ok_trk<= 1'b0;
        y1_min_acc <= MAXVAL;
        y1_max_acc <= {AW{1'b0}};
        y2_min_acc <= MAXVAL;
        y2_max_acc <= {AW{1'b0}};
        y1_seen    <= 1'b0;
        y2_seen    <= 1'b0;
        bond_valid <= 1'b0;
        bond_l     <= {AW{1'b0}};
        bond_r     <= {AW{1'b0}};
        bond_t     <= {AW{1'b0}};
        bond_b     <= {AW{1'b0}};
        center_x   <= {AW{1'b0}};
        center_y   <= {AW{1'b0}};
    end
    else if(state == S_SCAN) begin
        //--- (a) run 追蹤 ---
        if(lit) begin
            gap_cnt <= {AW{1'b0}};
            if(!run_act) begin
                run_act  <= 1'b1;
                run_st   <= scan_cnt[AW-1:0];
                run_last <= scan_cnt[AW-1:0];
            end
            else
                run_last <= scan_cnt[AW-1:0];   // 跨過小空隙繼續延伸
        end
        else if(run_act) begin
            if((gap_cnt < MERGE_GAP) && (scan_cnt < WIDTH))
                gap_cnt <= gap_cnt + 1'b1;
        end

        //--- (b) run 結束 → 更新兩個最寬候選（放後面，優先權最高）---
        if(run_fin) begin
            run_act <= 1'b0;
            gap_cnt <= {AW{1'b0}};
            if((run_w >= MIN_W) && (run_w <= MAX_W)) begin
                if(run_w > w1) begin
                    w2  <= w1 ; st2 <= st1; en2 <= en1;
                    w1  <= run_w; st1 <= run_st; en1 <= 1'b1;
                end
                else if(run_w > w2) begin
                    w2  <= run_w; st2 <= run_st; en2 <= 1'b1;
                end
            end
        end

        if(scan_cnt >= WIDTH)
            state <= S_LATCH;
        else
            scan_cnt <= scan_cnt + 1'b1;
    end
    else if(state == S_LATCH) begin
        // 出框：X 用「上一幀」的追蹤範圍，Y 用「本幀」累積的範圍
        bond_l     <= x1t_min;
        bond_r     <= x2t_max;
        bond_t     <= yy_top;
        bond_b     <= yy_bot;
        center_x   <= (x1t_min + x2t_max) >> 1;
        center_y   <= (yy_top + yy_bot) >> 1;
        bond_valid <= pair_ok_trk & y1_seen & y2_seen;

        // 更新追蹤用的 X 範圍為本幀投影結果
        if(pair_ok) begin
            x1t_min <= L_st;
            x1t_max <= L_st + L_w - 1'b1;
            x2t_min <= R_st;
            x2t_max <= R_st + R_w - 1'b1;
        end
        pair_ok_trk <= pair_ok;

        // 重置 Y 累加器，下一幀重新累積
        y1_min_acc <= MAXVAL;
        y1_max_acc <= {AW{1'b0}};
        y2_min_acc <= MAXVAL;
        y2_max_acc <= {AW{1'b0}};
        y1_seen    <= 1'b0;
        y2_seen    <= 1'b0;

        state <= S_IDLE;
    end
    else begin   // S_IDLE：幀內累積 Y 上下界
        if(vsync) begin
            state    <= S_SCAN;
            scan_cnt <= {(AW+1){1'b0}};
            run_act  <= 1'b0;
            gap_cnt  <= {AW{1'b0}};
            en1      <= 1'b0;
            en2      <= 1'b0;
            w1       <= {AW{1'b0}};
            w2       <= {AW{1'b0}};
            st1      <= {AW{1'b0}};
            st2      <= {AW{1'b0}};
        end
        else if(de && mask && (y > Y_GUARD) && pair_ok_trk) begin
            if((x >= x1t_min) && (x <= x1t_max)) begin
                if(!y1_seen) begin
                    y1_seen    <= 1'b1;
                    y1_min_acc <= y;
                    y1_max_acc <= y;
                end
                else begin
                    if(y < y1_min_acc) y1_min_acc <= y;
                    if(y > y1_max_acc) y1_max_acc <= y;
                end
            end
            else if((x >= x2t_min) && (x <= x2t_max)) begin
                if(!y2_seen) begin
                    y2_seen    <= 1'b1;
                    y2_min_acc <= y;
                    y2_max_acc <= y;
                end
                else begin
                    if(y < y2_min_acc) y2_min_acc <= y;
                    if(y > y2_max_acc) y2_max_acc <= y;
                end
            end
        end
    end
end

endmodule
