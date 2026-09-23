//****************************************Copyright (c)***********************************//
// File name:           proj_bond
// Descriptions:        列投影 + 灯条配对 + 边界框（用投影法取代连通域标记 CCL）
//
//   原理（灯条是“细长的垂直亮条”，用投影法比 CCL 便宜 5 倍也好调试）：
//     1. 整帧逐列累加：hist[x] = 第 x 列被判定为亮像素的个数
//     2. 帧结束后扫描 hist，找连续亮栏区间（run），取最宽的两个当候选灯条
//     3. X 范围确定后，在“下一帧”用这两个 X 范围累加 Y 的上下界
//     4. 两灯条宽度相近、间距合理 → 认定为装甲板，算出边界框与中心
//
//   【时间关系】扫描与出框都发生在垂直消隐期（vsync 脉冲之后），
//   约 802 个时钟就结束，离下一个有效显示行还有约 8000 个时钟，时间充裕。
//
//   【一个延迟】Y 的上下界是用“上一帧算出的 X 范围”累加的，
//   因此边界框会慢一帧才显示，对静态靶纸完全没有影响。
//----------------------------------------------------------------------------------------
//****************************************************************************************//
`timescale 1ns / 1ps

module proj_bond #(
    parameter WIDTH     = 800 ,   // 图像宽度（hist 深度）
    parameter AW        = 10  ,   // 坐标位宽
    parameter HW        = 10  ,   // hist 位宽（>= log2(图像高度)）
    parameter HIST_TH   = 48  ,   // 栏投影阈值：一列亮像素超过此值才算“亮栏”
    parameter MIN_W     = 6   ,   // 灯条最小宽度
    parameter MAX_W     = 240 ,   // 灯条最大宽度（超过视为大面积色块，丢弃）
    parameter MERGE_GAP = 4   ,   // 小于此间隙的两个 run 视为同一根灯条
    parameter MIN_GAP   = 10  ,   // 两灯条最小间距
    parameter MAX_GAP   = 520 ,   // 两灯条最大间距
    parameter Y_GUARD   = 16      // 忽略画面顶端无效行（行缓冲未填满）
)(
    input                clk       ,   // 时钟
    input                rst_n     ,   // 复位
    input                vsync     ,   // 帧起始脉冲（1 拍）
    input                de        ,   // 像素有效
    input      [AW-1:0]  x         ,   // 当前像素 x
    input      [AW-1:0]  y         ,   // 当前像素 y（有效行由 1 起算）
    input                mask      ,   // 最终二值图
    // 检测结果（屏幕坐标，供 overlay 画框）
    output reg           bond_valid,   // 边界框有效
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
(* ram_style = "distributed" *) reg [HW-1:0] hist [0:WIDTH-1];  // 栏投影直方图

reg  [1:0]  state     ;   // 主状态
reg  [AW:0] scan_cnt  ;   // 扫描计数（多跑一拍把最后一个 run 收尾）

reg         run_act   ;   // 目前正在一个 run 内
reg  [AW-1:0] run_st  ;   // run 起点
reg  [AW-1:0] run_last;   // run 最后一个亮栏
reg  [AW-1:0] gap_cnt ;   // run 内部的空隙计数

reg  [AW-1:0] w1, st1 ;   // 候选一（最宽）
reg  [AW-1:0] w2, st2 ;   // 候选二
reg         en1, en2  ;

reg  [AW-1:0] x1t_min, x1t_max ;   // 追踪用 X 范围（左灯条，来自上一帧）
reg  [AW-1:0] x2t_min, x2t_max ;   // 追踪用 X 范围（右灯条）
reg         pair_ok_trk        ;   // 追踪用的 X 范围是否为合法配对

reg  [AW-1:0] y1_min_acc, y1_max_acc ;   // 本帧累积的 Y 上下界（左灯条）
reg  [AW-1:0] y2_min_acc, y2_max_acc ;   // 本帧累积的 Y 上下界（右灯条）
reg         y1_seen, y2_seen         ;   // 是否看到过

//wire define
wire          scanning = (state == S_SCAN);
wire [AW-1:0] raddr    = scanning ? scan_cnt[AW-1:0] : x;
wire [HW-1:0] hval     = hist[raddr];                       // 异步读（标准 RAM 模板）
wire          lit      = scanning && (scan_cnt < WIDTH) && (hval >= HIST_TH);

// 单一写埠：扫描时清零、扫描外累加（Vivado 要单一写埠才会推断 RAM）
wire          hist_we    = scanning ? (scan_cnt < WIDTH)
                                    : (de && mask && (y > Y_GUARD) && (x < WIDTH));
wire [AW-1:0] hist_waddr = scanning ? scan_cnt[AW-1:0] : x;
wire [HW-1:0] hist_wdata = scanning ? {HW{1'b0}} : (hval + 1'b1);

wire [AW-1:0] run_w   = run_last - run_st + 1'b1;           // 目前 run 的宽度
wire          run_fin = run_act && (!lit) &&
                        ((scan_cnt >= WIDTH) || (gap_cnt >= MERGE_GAP));

// 两个候选依 x 位置排出左右
wire [AW-1:0] L_st = (st1 <= st2) ? st1 : st2;
wire [AW-1:0] L_w  = (st1 <= st2) ? w1  : w2 ;
wire [AW-1:0] R_st = (st1 <= st2) ? st2 : st1;
wire [AW-1:0] R_w  = (st1 <= st2) ? w2  : w1 ;
wire [AW:0]   gap  = {1'b0,R_st} - {1'b0,L_st} - {1'b0,L_w};  // 两灯条间距（可能下溢）

wire pair_ok = en1 & en2
             & (gap >= MIN_GAP) & (gap <= MAX_GAP)
             & ((L_w << 1) >= R_w) & ((R_w << 1) >= L_w);      // 宽度相差不超过两倍

wire [AW-1:0] yy_top = (y1_min_acc < y2_min_acc) ? y1_min_acc : y2_min_acc;
wire [AW-1:0] yy_bot = (y1_max_acc > y2_max_acc) ? y1_max_acc : y2_max_acc;

//*****************************************************
//**                    main code
//*****************************************************

//-------------------------------------------------------
// 直方图：单一写埠（扫描时清零 / 扫描外累加）
//-------------------------------------------------------
always @(posedge clk) begin
    if(hist_we)
        hist[hist_waddr] <= hist_wdata;
end

//-------------------------------------------------------
// 主状态机
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
        //--- (a) run 追踪 ---
        if(lit) begin
            gap_cnt <= {AW{1'b0}};
            if(!run_act) begin
                run_act  <= 1'b1;
                run_st   <= scan_cnt[AW-1:0];
                run_last <= scan_cnt[AW-1:0];
            end
            else
                run_last <= scan_cnt[AW-1:0];   // 跨过小空隙继续延伸
        end
        else if(run_act) begin
            if((gap_cnt < MERGE_GAP) && (scan_cnt < WIDTH))
                gap_cnt <= gap_cnt + 1'b1;
        end

        //--- (b) run 结束 → 更新两个最宽候选（放后面，优先权最高）---
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
        // 出框：X 用“上一帧”的追踪范围，Y 用“本帧”累积的范围
        bond_l     <= x1t_min;
        bond_r     <= x2t_max;
        bond_t     <= yy_top;
        bond_b     <= yy_bot;
        center_x   <= (x1t_min + x2t_max) >> 1;
        center_y   <= (yy_top + yy_bot) >> 1;
        bond_valid <= pair_ok_trk & y1_seen & y2_seen;

        // 更新追踪用的 X 范围为本帧投影结果
        if(pair_ok) begin
            x1t_min <= L_st;
            x1t_max <= L_st + L_w - 1'b1;
            x2t_min <= R_st;
            x2t_max <= R_st + R_w - 1'b1;
        end
        pair_ok_trk <= pair_ok;

        // 重置 Y 累加器，下一帧重新累积
        y1_min_acc <= MAXVAL;
        y1_max_acc <= {AW{1'b0}};
        y2_min_acc <= MAXVAL;
        y2_max_acc <= {AW{1'b0}};
        y1_seen    <= 1'b0;
        y2_seen    <= 1'b0;

        state <= S_IDLE;
    end
    else begin   // S_IDLE：帧内累积 Y 上下界
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
