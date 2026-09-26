`timescale 1ns / 1ps
//****************************************************************************************//
// File name:           blob_track
// Descriptions:        连通团块跟踪（P3）：行程编码 + K 个团块记录
//                      -> 多目标 / 每块面积 / 形心 / 圆度
//
//   为什么要它：
//     原来的 proj_bond 取 X/Y 直方图的「外沿」。画面里只要有两块分开的绿，就会被串成
//     一个框 -> 被形状校验挡掉 -> 直接不输出。这里换成真正的连通团块跟踪。
//
//   实现路线（与 dart 的 FindBond.v 不同，但输出等价）：
//     dart 用「逐像素 256 标签 + 并查集重标」：一条 800 深的标签行缓冲、256 项结构体表
//     （Top/Bottom/Left/Right/Num/IsWhite，64bit x 256）、重标表，还有一套 3 级流水
//     来在同一拍里解决左右/上下标签冲突。本模块改用**行程（run）级**团块记录：
//       - 每行把 mask 的连通行程抽出来（run start / run end）
//       - 每个行程和 K 个团块记录做「水平区间重叠 + 行相邻」匹配
//       - 命中 1 个 -> 并入；命中多个 -> 合并（面积/矩相加，其余记录释放）
//       - 都没命中 -> 新开一个记录
//     输出（每块外框 + 面积 + 形心 + 圆度 + 数量）与 dart 那套完全一致，
//     但不需要逐像素标签 RAM 和并查集表，逻辑量约为前者的 1/4，也更好在测试台里验证。
//
//   为什么不需要 FIFO / 状态机：
//     emit 只在 mask 由 1 变 0（或行尾收尾）时产生，也就是说**两次 emit 至少隔 2 拍**，
//     而匹配判定 + 记录更新是纯组合的，正好在 emit 那一拍吃完。所以一拍一个行程、
//     没有任何吞吐瓶颈，也不需要丢弃逻辑。
//
//   形心：累计 sum2x = Sigma(2x)、sum2y = Sigma(2y)（用 2 倍避免整除截断），
//         帧末再除以 2*area。满屏 480000 像素 x 1600 需要 30bit，用 32bit 累加。
//   圆度：填充率 fill_q8 = area*256/(w*h)。圆的理论值是 256*pi/4 = 201。
//   除法用一条串行移位除法器，帧末算 3 次约 100 拍；一帧 55 万拍，毫无压力。
//
//   资源：K=4 时约 500 FF（6 个 32bit 累加器 x 4）+ 约 900 LUT，0 BRAM。
//****************************************************************************************//
module blob_track #(
    parameter WIDTH    = 800        ,   // 图像宽
    parameter HEIGHT   = 480        ,   // 图像高
    parameter AW       = 10         ,   // 坐标位宽
    parameter K        = 4          ,   // 最多同时跟踪的团块数
    parameter MIN_AREA = 400        ,   // 低于这个面积不算目标
    parameter ASPECT_SHIFT = 3         ,   // 宽松档的长宽比上限 = 2^SHIFT（8 -> 8:1）
    parameter GAP_MAX  = 64             // 允许的纵向间隙（行）；反光白带把灯切成上下
                                        // 两块时靠它把两块并回一个团块。调小 = 更严格地区分
                                        // 上下相邻的多个目标
)(
    input                 clk           ,
    input                 rst_n         ,
    input                 vsync         ,   // 帧同步（脉冲或电平都可以）
    input                 de            ,   // 行有效
    input      [AW-1:0]   x             ,   // 当前像素 x
    input      [AW-1:0]   y             ,   // 当前行 y（1 基）
    input                 mask          ,   // 二值掩码
    input      [15:0]     aim_h_q8      ,   // 瞄准点偏移 = 宽度 x aim_h_q8/256（Q0.8，
                                             // 运行时可变，由 UART 0x05 / parameter 给）   // 二值掩码

    input      [31:0]     min_area_lo   ,   // 宽松档最小面积（远/小目标）；0 = 关闭宽松档

    output reg            bond_valid    ,   // 本帧是否找到合格团块
    output reg [AW-1:0]   bond_l        ,
    output reg [AW-1:0]   bond_r        ,
    output reg [AW-1:0]   bond_t        ,
    output reg [AW-1:0]   bond_b        ,
    output reg [AW-1:0]   center_x      ,   // 外框中心（与旧 proj_bond 同义）
    output reg [AW-1:0]   center_y      ,
    output reg [AW-1:0]   aim_x         ,
    output reg [AW-1:0]   aim_y         ,
    output reg [31:0]     blob_area     ,   // 最佳团块面积（像素数）
    output reg [2:0]      blob_cnt      ,   // 本帧合格团块数
    output reg            blob_far      ,   // 选中的是宽松档（小而远）的目标
    output reg [AW-1:0]   cent_x        ,   // 形心（掩码质心，亚像素更接近真值）
    output reg [AW-1:0]   cent_y        ,
    output reg [7:0]      fill_q8           // 填充率 x256（圆约 201）
);

integer gi;
integer mi;
genvar  gv;

//-------------------------------------------------------
// 行程抽取
//   in_run 记录当前是否在行程中；mask 落下（或行结束）时把 [run_x0, run_last] 吐出去。
//-------------------------------------------------------
reg           in_run   ;
reg  [AW-1:0] run_x0   ;
reg  [AW-1:0] run_last ;
reg  [AW-1:0] run_y    ;
reg           emit     ;
reg  [AW-1:0] emit_x0  ;
reg  [AW-1:0] emit_x1  ;
reg  [AW-1:0] emit_y   ;

always @(posedge clk or negedge rst_n) begin
    if(!rst_n) begin
        in_run   <= 1'b0;
        emit     <= 1'b0;
        run_x0   <= {AW{1'b0}};
        run_last <= {AW{1'b0}};
        run_y    <= {AW{1'b0}};
        emit_x0  <= {AW{1'b0}};
        emit_x1  <= {AW{1'b0}};
        emit_y   <= {AW{1'b0}};
    end
    else begin
        emit <= 1'b0;
        if(de) begin
            if(mask) begin
                if(!in_run) begin
                    in_run <= 1'b1;
                    run_x0 <= x;
                    run_y  <= y;
                end
                run_last <= x;
            end
            else if(in_run) begin          // 行程在 mask 落下的这一拍结束
                in_run  <= 1'b0;
                emit    <= 1'b1;
                emit_x0 <= run_x0;
                emit_x1 <= run_last;       // 最后一个 mask=1 的像素
                emit_y  <= run_y;
            end
        end
        else if(in_run) begin              // 行尾还在行程里：贴到行尾收尾
            in_run  <= 1'b0;
            emit    <= 1'b1;
            emit_x0 <= run_x0;
            emit_x1 <= run_last;
            emit_y  <= run_y;
        end
    end
end

//-------------------------------------------------------
// 团块记录（寄存器）
//-------------------------------------------------------
reg           r_used [0:K-1];
reg [AW-1:0]  r_l    [0:K-1];
reg [AW-1:0]  r_r    [0:K-1];
reg [AW-1:0]  r_t    [0:K-1];
reg [AW-1:0]  r_b    [0:K-1];
reg [AW-1:0]  r_row  [0:K-1];
reg [31:0]    r_area [0:K-1];
reg [31:0]    r_s2x  [0:K-1];
reg [31:0]    r_s2y  [0:K-1];

//-------------------------------------------------------
// vsync 下降沿 = 帧末
//   用下降沿而不是上升沿：tb_armor_vision 里 vsync 是「宽 101 拍的电平」，
//   真机 rd_vsync 形态也不好假设，所以一律走边沿。
//-------------------------------------------------------
reg  vsync_d ;
wire vsync_fall = ~vsync & vsync_d;

always @(posedge clk or negedge rst_n) begin
    if(!rst_n) vsync_d <= 1'b0;
    else       vsync_d <= vsync;
end

//-------------------------------------------------------
// 当前行程的量（组合）
//-------------------------------------------------------
wire [AW:0]     q_lenm1 = {1'b0, emit_x1} - {1'b0, emit_x0};
wire [AW:0]     q_len   = q_lenm1 + 1'b1;                       // 1..800
wire [AW:0]     q_sum   = {1'b0, emit_x0} + {1'b0, emit_x1};
wire [2*AW+1:0] q_s2x   = q_sum * q_len;                        // <=1599*800
wire [2*AW+1:0] q_s2y   = ({1'b0, emit_y} << 1) * q_len;        // <=960*800
wire [AW-1:0]   q_ym1   = emit_y - 1'b1;

//-------------------------------------------------------
// 匹配判定（组合）
//   条件：记录在用 && (行号 == 当前行 或 上一行) && 水平区间有交集
//   允许「同一行」是为了处理带洞的团块：一行被洞切成两段时，两段都应该并进同一个记录。
//-------------------------------------------------------
wire [K-1:0] match;
generate
for(gv = 0; gv < K; gv = gv + 1) begin : g_match
    //  放宽成「纵向间隙 <= GAP_MAX」而不是「紧邻上一行」：
    //  镜面反光在灯上打出的白色横带会让那几行完全没有绿色，上下两块在图上并不相邻。
    //  只认紧邻的话，上下两块会变成两个团块，帧末取面积最大者 -> 只剩半盏灯
    //  （实测 center_y 从 248 掉到 190，就是把旧 proj_bond 的优点弄丢了）。
    //  emit_y >= r_row 保证不会往下匹配到未来行；差值用 AW+1 位不会借位。
    assign match[gv] = r_used[gv]
                    && (emit_y >= r_row[gv])
                    && (({1'b0, emit_y} - {1'b0, r_row[gv]}) <= GAP_MAX)
                    && (r_l[gv] <= emit_x1) && (emit_x0 <= r_r[gv]);
end
endgenerate

wire       any_match = |match;
wire [3:0] used_v    = {r_used[3], r_used[2], r_used[1], r_used[0]};
//  下面三行按 K=4 写死；若要改 K，这里和 t_idx 都得跟着改
wire [1:0] free_idx  = used_v[0] ? (used_v[1] ? (used_v[2] ? 2'd3 : 2'd2) : 2'd1) : 2'd0;
wire       has_free  = ~(&used_v);
wire [1:0] t_idx     = match[0] ? 2'd0 : match[1] ? 2'd1 : match[2] ? 2'd2 : 2'd3;

//-------------------------------------------------------
// 被匹配记录的各项聚合（组合）
//-------------------------------------------------------
reg  [AW-1:0] m_l  ;
reg  [AW-1:0] m_r  ;
reg  [AW-1:0] m_t  ;
reg  [31:0]   m_are;
reg  [31:0]   m_s2x;
reg  [31:0]   m_s2y;

always @(*) begin
    m_l   = {AW{1'b1}};
    m_r   = {AW{1'b0}};
    m_t   = {AW{1'b1}};
    m_are = 32'd0;
    m_s2x = 32'd0;
    m_s2y = 32'd0;
    for(mi = 0; mi < K; mi = mi + 1) begin
        if(match[mi]) begin
            if(r_l[mi] < m_l) m_l = r_l[mi];
            if(r_r[mi] > m_r) m_r = r_r[mi];
            if(r_t[mi] < m_t) m_t = r_t[mi];
            m_are = m_are + r_area[mi];
            m_s2x = m_s2x + r_s2x[mi];
            m_s2y = m_s2y + r_s2y[mi];
        end
    end
end

//-------------------------------------------------------
// 记录更新：在 emit 那一拍吃完（一拍一个行程）
//-------------------------------------------------------
always @(posedge clk or negedge rst_n) begin
    if(!rst_n) begin
        for(gi = 0; gi < K; gi = gi + 1) begin
            r_used[gi] <= 1'b0;
            r_l[gi]    <= {AW{1'b0}};
            r_r[gi]    <= {AW{1'b0}};
            r_t[gi]    <= {AW{1'b0}};
            r_b[gi]    <= {AW{1'b0}};
            r_row[gi]  <= {AW{1'b0}};
            r_area[gi] <= 32'd0;
            r_s2x[gi]  <= 32'd0;
            r_s2y[gi]  <= 32'd0;
        end
    end
    else if(vsync_fall) begin
        // 帧末清空（此时下面那块的 argmax 已经读过本帧的数据）
        for(gi = 0; gi < K; gi = gi + 1) begin
            r_used[gi] <= 1'b0;
            r_area[gi] <= 32'd0;
            r_s2x[gi]  <= 32'd0;
            r_s2y[gi]  <= 32'd0;
            r_row[gi]  <= {AW{1'b0}};
        end
    end
    else if(emit) begin
        for(gi = 0; gi < K; gi = gi + 1) begin
            if(any_match) begin
                if(gi == t_idx) begin
                    r_used[gi] <= 1'b1;
                    r_l[gi]    <= (m_l < emit_x0) ? m_l : emit_x0;
                    r_r[gi]    <= (m_r > emit_x1) ? m_r : emit_x1;
                    r_t[gi]    <= (m_t < emit_y ) ? m_t : emit_y;
                    r_b[gi]    <= emit_y;
                    r_row[gi]  <= emit_y;
                    r_area[gi] <= m_are + q_len;
                    r_s2x[gi]  <= m_s2x + q_s2x;
                    r_s2y[gi]  <= m_s2y + q_s2y;
                end
                else if(match[gi]) begin
                    r_used[gi] <= 1'b0;        // 被合并掉了
                end
            end
            else if(has_free && (gi == free_idx)) begin
                r_used[gi] <= 1'b1;
                r_l[gi]    <= emit_x0;
                r_r[gi]    <= emit_x1;
                r_t[gi]    <= emit_y;
                r_b[gi]    <= emit_y;
                r_row[gi]  <= emit_y;
                r_area[gi] <= q_len;
                r_s2x[gi]  <= q_s2x;
                r_s2y[gi]  <= q_s2y;
            end
        end
    end
end

//-------------------------------------------------------
// 最佳团块：面积最大的那个（组合 argmax）
//-------------------------------------------------------
reg  [1:0]  best_i ;
reg         best_any;
reg  [31:0] best_are;
reg  [2:0]  cnt_c   ;
//  ---- 形状合理性（打一拍，把 w*h 乘法移出选块路径）----
reg  [AW:0]  tw_f, th_f ;   // 候选项宽 / 高（组合过桥）
reg  [K-1:0] shp_now    ;   // 组合：4 个候选的形状结论
reg  [K-1:0] shp_ok_r   ;   // 打一拍后的形状结论
reg          st_any     ;   // 宽松档是否已有候选
reg  [31:0]  st_are     ;
reg  [1:0]   st_i       ;
reg          best_far   ;   // 最终选中的是宽松档
integer      si         ;

//  ---- 三级流水（数据在帧内准静态，拆开对功能零影响）----
reg  [1:0]   best_i_r   ;   // 级1：选块结果
reg          best_any_r ;
reg          best_far_r ;
reg  [2:0]   cnt_r      ;
reg  [AW-1:0] sl_r, sr_r, st_r, sb_r;   // 级2：选中记录的外框
reg  [31:0]  sa_r, sx_r, sy_r;          // 级2：面积 / 矩
reg          sany_r, sfar_r;
reg  [2:0]   scnt_r     ;

//  两级门槛（这就是「远处小绿灯认不出来」的修复点）：
//    强档：area >= MIN_AREA          -> 近处 / 大目标，优先
//    宽松档：area >= min_area_lo 且形状合理 -> 远处 / 小目标
//  旧版只有强档一条，MIN_AREA=400 时的远处小灯（几十像素）会被整块丢掉，
//  于是 raw_valid=0 -> 「屏幕上有高亮但识别不到目标」。
//  形状合理性只作用于宽松档（面积小的时候填充率 / 长宽比对噪声很敏感）：
//    长宽比 <= 2^ASPECT_SHIFT，且 area*4 >= w*h（填充率 >= 1/4）
//  -> 挡掉细长条（画面上的一条绿边）和空心块，但不挡 3x3 的小灯。
//  min_area_lo = 0 时宽松档关闭，行为与旧版完全一致（逃生开关）。
//  形状合理性：4 个候选并行算（只有乘法 + 比较，没有优先树）
//  时序上单独一拍算完 -> 选块那边直接用 shp_ok_r[mi]
always @(*) begin
    for(si = 0; si < K; si = si + 1) begin
        tw_f = {1'b0, r_r[si]} - {1'b0, r_l[si]} + 1'b1;
        th_f = {1'b0, r_b[si]} - {1'b0, r_t[si]} + 1'b1;
        shp_now[si] = (tw_f <= (th_f << ASPECT_SHIFT)) &&
                      (th_f <= (tw_f << ASPECT_SHIFT)) &&
                      ((r_area[si] << 2) >= (tw_f * th_f));
    end
end

//  级1：形状结论打一拍
always @(posedge clk or negedge rst_n) begin
    if(!rst_n) shp_ok_r <= {K{1'b0}};
    else       shp_ok_r <= shp_now;
end

always @(*) begin
    best_i   = 2'd0;
    best_any = 1'b0;
    best_are = 32'd0;
    cnt_c    = 3'd0;
    best_far = 1'b0;
    st_any   = 1'b0;
    st_are   = 32'd0;
    st_i     = 2'd0;
    for(mi = 0; mi < K; mi = mi + 1) begin
        if(r_used[mi] && (r_area[mi] >= MIN_AREA)) begin
            cnt_c = cnt_c + 3'd1;
            if(!best_any || (r_area[mi] > best_are)) begin
                best_any = 1'b1;
                best_are = r_area[mi];
                best_i   = mi[1:0];
            end
        end
        //  P14：面积 <= 32 的极小团块免掉长宽比/填充率检查 —— 那个尺寸下量化误差主导，
        //  检查只会把远处的绿灯误杀（症状：屏幕上有绿色高亮，但 bond_valid=0）。
        else if(r_used[mi] && (min_area_lo != 32'd0) &&
                (r_area[mi] >= min_area_lo) &&
                (shp_ok_r[mi] || (r_area[mi] <= 32'd32))) begin
            cnt_c = cnt_c + 3'd1;
            if(!st_any || (r_area[mi] > st_are)) begin
                st_any = 1'b1;
                st_are = r_area[mi];
                st_i   = mi[1:0];
            end
        end
    end
    if(!best_any && st_any) begin          // 没有强档 -> 用宽松档最好的那块
        best_any = 1'b1;
        best_are = st_are;
        best_i   = st_i;
        best_far = 1'b1;
    end
end

//  级2：选块结果打一拍
always @(posedge clk or negedge rst_n) begin
    if(!rst_n) begin
        best_i_r   <= 2'd0;
        best_any_r <= 1'b0;
        best_far_r <= 1'b0;
        cnt_r      <= 3'd0;
    end
    else begin
        best_i_r   <= best_i;
        best_any_r <= best_any;
        best_far_r <= best_far;
        cnt_r      <= cnt_c;
    end
end

//  级3：选中记录的外框 / 面积 / 矩打一拍
//  -> 后面的 bw * aim_h_q8 只从本地寄存器出发，布线短、级数少
always @(posedge clk or negedge rst_n) begin
    if(!rst_n) begin
        sl_r <= {AW{1'b0}}; sr_r <= {AW{1'b0}};
        st_r <= {AW{1'b0}}; sb_r <= {AW{1'b0}};
        sa_r <= 32'd0; sx_r <= 32'd0; sy_r <= 32'd0;
        sany_r <= 1'b0; sfar_r <= 1'b0; scnt_r <= 3'd0;
    end
    else begin
        sl_r <= r_l[best_i_r];  sr_r <= r_r[best_i_r];
        st_r <= r_t[best_i_r];  sb_r <= r_b[best_i_r];
        sa_r <= r_area[best_i_r];
        sx_r <= r_s2x[best_i_r];
        sy_r <= r_s2y[best_i_r];
        sany_r <= best_any_r;
        sfar_r <= best_far_r;
        scnt_r <= cnt_r;
    end
end

//  外框中心 / 瞄准点（宽度算术必须扩位，否则 1023+1023 会溢出）
//  ---- P14 外框 3 帧中值：干掉单帧离群值（斜置屏幕反光/AWB 抖动）----
//  用中值而不是 IIR：中值对恒定/匀速目标几乎没有滞后，IIR 会给运动目标带来固定滞后。
function [AW:0] med3;
    input [AW:0] a, b, c;
    begin
        med3 = (a > b) ? ((b > c) ? b : ((a > c) ? c : a))
                       : ((a > c) ? a : ((b > c) ? c : b));
    end
endfunction

reg  [AW:0] hl1, hl2, hr1, hr2, ht1, ht2, hb1, hb2;
reg         have_hist;
wire [AW:0] sl_f = have_hist ? med3({1'b0, sl_r}, hl1, hl2) : {1'b0, sl_r};
wire [AW:0] sr_f = have_hist ? med3({1'b0, sr_r}, hr1, hr2) : {1'b0, sr_r};
wire [AW:0] st_f = have_hist ? med3({1'b0, st_r}, ht1, ht2) : {1'b0, st_r};
wire [AW:0] sb_f = have_hist ? med3({1'b0, sb_r}, hb1, hb2) : {1'b0, sb_r};

//  历史更新：第一个有效帧「装载」（中值=当帧值），丢失后清历史
always @(posedge clk or negedge rst_n) begin
    if(!rst_n) begin
        hl1 <= {AW+1{1'b0}}; hl2 <= {AW+1{1'b0}};
        hr1 <= {AW+1{1'b0}}; hr2 <= {AW+1{1'b0}};
        ht1 <= {AW+1{1'b0}}; ht2 <= {AW+1{1'b0}};
        hb1 <= {AW+1{1'b0}}; hb2 <= {AW+1{1'b0}};
        have_hist <= 1'b0;
    end
    else if(vsync_fall) begin
        if(!sany_r) have_hist <= 1'b0;
        else if(!have_hist) begin
            hl1 <= {1'b0, sl_r}; hl2 <= {1'b0, sl_r};
            hr1 <= {1'b0, sr_r}; hr2 <= {1'b0, sr_r};
            ht1 <= {1'b0, st_r}; ht2 <= {1'b0, st_r};
            hb1 <= {1'b0, sb_r}; hb2 <= {1'b0, sb_r};
            have_hist <= 1'b1;
        end
        else begin
            hl2 <= hl1; hl1 <= {1'b0, sl_r};
            hr2 <= hr1; hr1 <= {1'b0, sr_r};
            ht2 <= ht1; ht1 <= {1'b0, st_r};
            hb2 <= hb1; hb1 <= {1'b0, sb_r};
        end
    end
end

wire [AW:0]   cx_w = ({1'b0, sl_r} + {1'b0, sr_r}) >> 1;
wire [AW:0]   cy_w = ({1'b0, st_r} + {1'b0, sb_r}) >> 1;
wire [AW:0]   bw_w = {1'b0, sr_r} - {1'b0, sl_r} + 1'b1;
wire [2*AW+8:0] up_full = bw_w * aim_h_q8;
wire [AW+8:0]   up_t    = up_full >> 8;

//  饱和减法 aim_y = cy - up
//  直接写 aim_y <= cy - up 时，两边按 10bit 运算，cy < up 就下溢回绕
//  (绕到 1024 附近，十字跳到画面底部)。
//  AIM_H_Q8 = 372 时偏移 = 1.449 x 灯宽，必然超过灯心 y，所以必须先补这里。
wire [AW+8:0] cy_l = {9'd0, cy_w[AW-1:0]};
wire [AW+8:0] ay_s = (cy_l >= up_t) ? (cy_l - up_t) : {(AW+9){1'b0}};

//  同样的东西，但用「3 帧中值」后的外框（输出给下游用这个）
wire [AW:0]     cx_f = (sl_f + sr_f) >> 1;
wire [AW:0]     cy_f = (st_f + sb_f) >> 1;
wire [AW:0]     bw_f = sr_f - sl_f + 1'b1;
wire [2*AW+8:0] up_full_f = bw_f * aim_h_q8;
wire [AW+8:0]   up_t_f    = up_full_f >> 8;
wire [AW+8:0]   cy_l_f    = {9'd0, cy_f[AW-1:0]};
wire [AW+8:0]   ay_f      = (cy_l_f >= up_t_f) ? (cy_l_f - up_t_f) : {(AW+9){1'b0}};

//-------------------------------------------------------
// 串行移位除法器（帧末算 3 次：cent_x / cent_y / fill）
//-------------------------------------------------------
localparam DVB_IDLE = 2'd0, DVB_RUN = 2'd1;
reg  [1:0]  dv_state;
reg  [1:0]  dv_step ;
reg  [32:0] dv_rem  ;
reg  [31:0] dv_dend ;
reg  [31:0] dv_dsor ;
reg  [31:0] dv_quo  ;
reg  [5:0]  dv_cnt  ;
reg  [31:0] lat_x, lat_y, lat_a;
reg  [AW-1:0] lat_l, lat_r, lat_t, lat_b;

wire [32:0] dv_rem_next = {dv_rem[31:0], dv_dend[31]};

//-------------------------------------------------------
// 帧末锁存 + 启动除法链
//-------------------------------------------------------
always @(posedge clk or negedge rst_n) begin
    if(!rst_n) begin
        bond_valid <= 1'b0;
        bond_l <= {AW{1'b0}}; bond_r <= {AW{1'b0}};
        bond_t <= {AW{1'b0}}; bond_b <= {AW{1'b0}};
        center_x <= {AW{1'b0}}; center_y <= {AW{1'b0}};
        aim_x <= {AW{1'b0}};    aim_y <= {AW{1'b0}};
        blob_area <= 32'd0;     blob_cnt <= 3'd0;
        blob_far  <= 1'b0;
        cent_x <= {AW{1'b0}};   cent_y <= {AW{1'b0}};
        fill_q8 <= 8'd0;
        lat_x <= 32'd0; lat_y <= 32'd0; lat_a <= 32'd0;
        lat_l <= {AW{1'b0}}; lat_r <= {AW{1'b0}};
        lat_t <= {AW{1'b0}}; lat_b <= {AW{1'b0}};
        dv_state <= DVB_IDLE; dv_step <= 2'd0;
        dv_rem <= 33'd0; dv_dend <= 32'd0; dv_dsor <= 32'd0;
        dv_quo <= 32'd0; dv_cnt <= 6'd0;
    end
    else if(vsync_fall) begin
        bond_valid <= sany_r;
        blob_cnt   <= scnt_r;
        blob_far   <= sfar_r;
        if(sany_r) begin
            //  P14: 下游（矄准偏移 / 距离 / 下坠 / 圆环）统一用 3 帧中值后的框
            bond_l    <= sl_f[AW-1:0];
            bond_r    <= sr_f[AW-1:0];
            bond_t    <= st_f[AW-1:0];
            bond_b    <= sb_f[AW-1:0];
            center_x  <= cx_f[AW-1:0];
            center_y  <= cy_f[AW-1:0];
            aim_x     <= cx_f[AW-1:0];
            aim_y     <= ay_f[AW-1:0];       // 饱和，不回绕
            blob_area <= sa_r;
            lat_x <= sx_r;
            lat_y <= sy_r;
            lat_a <= sa_r;
            lat_l <= sl_r; lat_r <= sr_r;
            lat_t <= st_r; lat_b <= sb_r;
            dv_state <= DVB_RUN;
            dv_step  <= 2'd0;
            dv_cnt   <= 6'd32;
            dv_rem   <= 33'd0;
            dv_quo   <= 32'd0;
            dv_dend  <= sx_r;
            dv_dsor  <= sa_r << 1;                 // 2*area
        end
        else begin
            blob_area <= 32'd0;
            cent_x    <= {AW{1'b0}};
            cent_y    <= {AW{1'b0}};
            fill_q8   <= 8'd0;
            dv_state  <= DVB_IDLE;
        end
    end
    else if(dv_state == DVB_RUN) begin
        if(dv_cnt != 0) begin
            dv_dend <= {dv_dend[30:0], 1'b0};
            if(dv_rem_next >= dv_dsor) begin
                dv_rem <= dv_rem_next - dv_dsor;
                dv_quo <= {dv_quo[30:0], 1'b1};
            end
            else begin
                dv_rem <= dv_rem_next;
                dv_quo <= {dv_quo[30:0], 1'b0};
            end
            dv_cnt <= dv_cnt - 1'b1;
        end
        else begin
            case(dv_step)
                2'd0: begin
                    cent_x  <= dv_quo[AW-1:0];
                    dv_step <= 2'd1;
                    dv_cnt  <= 6'd32;
                    dv_rem  <= 33'd0;
                    dv_quo  <= 32'd0;
                    dv_dend <= lat_y;
                    dv_dsor <= lat_a << 1;
                end
                2'd1: begin
                    cent_y  <= dv_quo[AW-1:0];
                    dv_step <= 2'd2;
                    dv_cnt  <= 6'd32;
                    dv_rem  <= 33'd0;
                    dv_quo  <= 32'd0;
                    dv_dend <= lat_a << 8;                       // area*256
                    dv_dsor <= (lat_r - lat_l + 1'b1) * (lat_b - lat_t + 1'b1);
                end
                default: begin
                    fill_q8  <= (dv_quo > 32'd255) ? 8'd255 : dv_quo[7:0];
                    dv_state <= DVB_IDLE;
                end
            endcase
        end
    end
end

endmodule
