//****************************************Copyright (c)***********************************//
// File name:           tb_armor_vision
// Descriptions:        armor_vision 自检测试台（xsim 直接跑，不需要 DDR3 模型）
//
//   模拟场景：800x480 @25MHz（和 39 例程的 LCD 时序相同）
//     - 背景：灰 0x8410
//     - 靶标：一个【绿色实心圆】，圆心 (400,240)、半径 100（原图坐标）
//             绿 = 0x750E -> r8=118  g8=162  b8=118
//             所以 G-R = G-B = 44，正好可以用来验证 TH_G-R 阈值有没有生效
//     - 相位 2 会盖一条【白色眩光带】(py 225..255) 横穿圆心，模拟 LCD 镜面反光
//     - rddata 与 rdata_req 打一拍（与 ddr3_fifo_ctrl 一致）
//
//   期望值的推导见 doc/vision_pipeline.md：
//     形态学「右下角对齐」-> 二值图整体右下偏 8 -> 圆心 (408,248)、半径仍 100
//     投影阈值 TH_MIN=4：一列弦长 >= 4 要求 |d| <= 99 -> bl/br = 309/507、bt/bb = 149/347
//     圆环半径 = (199+199)/4 = 99（环带 97..101）
//     瞄准点 = 圆心往上 宽度*64/256 = 199/4 = 49 -> (408, 199)
//----------------------------------------------------------------------------------------
//****************************************************************************************//

`timescale 1ns / 1ps

module tb_armor_vision;

//-------------------------------------------------------
// 时序参数（与 lcd_driver.v 的 800x480 一致）
//-------------------------------------------------------
localparam H_TOTAL = 1056;
localparam H_SYNC  = 128 ;
localparam H_BACK  = 88  ;
localparam H_DISP  = 800 ;
localparam V_TOTAL = 525 ;
localparam V_SYNC  = 2   ;
localparam V_BACK  = 33  ;
localparam V_DISP  = 480 ;
localparam CLK_P   = 40;     // 25MHz

//-------------------------------------------------------
// 合成图像：一个绿色实心圆 + 可选白色眩光带
//-------------------------------------------------------
localparam CX_IMG = 400;
localparam CY_IMG = 240;
localparam GLARE_T = 225;    // 眩光带上下沿（py）
localparam GLARE_B = 255;

//-------------------------------------------------------
// 期望值（无眩光）
//-------------------------------------------------------
localparam EXP_L  = 10'd309;
localparam EXP_R  = 10'd507;
localparam EXP_T  = 10'd149;
localparam EXP_B  = 10'd347;
localparam EXP_CX = 10'd408;
localparam EXP_CY = 10'd248;
localparam EXP_W  = 11'd199;
localparam EXP_AY = 10'd199;   // 瞄准点 y

//-------------------------------------------------------
// 期望值（有眩光带时）—— 只有宽度会缩 1 像素，高度和圆心必须不变
//   （旧版「取最长 run」在这里会退化成 h≈84、center_y≈190，就是「识别不到」的现场）
//-------------------------------------------------------
localparam GLA_L  = 10'd310;
localparam GLA_R  = 10'd506;
localparam GLA_W  = 11'd197;

//-------------------------------------------------------
// 颜色
//-------------------------------------------------------
localparam GREEN_PIX = 16'h750E;   // 靶标绿（原色）
localparam GRAY_PIX  = 16'h8410;   // 背景灰
localparam DIM_PIX   = 16'h4208;   // 背景灰变暗后的值
localparam MARK_PIX  = 16'hF800;   // 标记红
localparam BIN_W     = 16'hFFFF;   // 纯二值模式：命中 = 白
localparam GLARE_PIX = 16'hFFFF;   // 眩光带白

//reg define
reg         clk   = 1'b0;
reg         rst_n = 1'b0;
reg  [10:0] h_cnt = 11'd0;
reg  [10:0] v_cnt = 11'd0;
reg  [3:0]  key   = 4'b1111;      // 全部松开
reg         glare_on = 1'b0;      // 1 = 打开眩光带
reg  [15:0] data_in;

//wire define
wire de    = (h_cnt >= (H_SYNC+H_BACK-2)) && (h_cnt < (H_SYNC+H_BACK+H_DISP-2))
          && (v_cnt >= (V_SYNC+V_BACK))   && (v_cnt < (V_SYNC+V_BACK+V_DISP));
wire vsync = (h_cnt <= 11'd100) && (v_cnt == 11'd1);
wire [10:0] px = h_cnt - (H_SYNC+H_BACK-2);
wire [10:0] py = v_cnt - (V_SYNC+V_BACK) + 11'd1;

wire [15:0] data_out;
wire [3:0]  led;
wire [5:0]  seg_sel;
wire [7:0]  seg_led;
wire        bond_valid;
wire [9:0]  center_x, center_y;
wire [9:0]  aim_x, aim_y;

reg [31:0] frame_cnt = 32'd0;
reg [15:0] cap_in, cap_bg, cap_ring, cap_cctr, cap_aim;
reg [31:0] err_cnt = 32'd0;

// 做差要显式带符号，否则 px<400 时会变成无符号大数
wire signed [11:0] dxc = $signed({1'b0,px}) - 12'sd400;
wire signed [11:0] dyc = $signed({1'b0,py}) - 12'sd240;
wire [23:0] d2c = dxc*dxc + dyc*dyc;
wire in_circle = (d2c <= 24'd10000);

//*****************************************************
//**                    main code
//*****************************************************

// 时钟
always #(CLK_P/2) clk = ~clk;

//-------------------------------------------------------
// 产生整帧时序
//-------------------------------------------------------
always @(posedge clk) begin
    if(!rst_n) begin
        h_cnt <= 11'd0;
        v_cnt <= 11'd0;
    end
    else if(h_cnt == H_TOTAL-1) begin
        h_cnt <= 11'd0;
        v_cnt <= (v_cnt == V_TOTAL-1) ? 11'd0 : (v_cnt + 11'd1);
    end
    else
        h_cnt <= h_cnt + 11'd1;
end

// 帧计数
always @(posedge clk) begin
    if(rst_n && vsync && (h_cnt == 11'd0))
        frame_cnt <= frame_cnt + 32'd1;
end

//-------------------------------------------------------
// 合成测试图像：绿圆，相位 2 再盖一条白色眩光带
//-------------------------------------------------------
always @(*) begin
    data_in = GRAY_PIX;
    if((px <= 11'd799) && (py >= 11'd1) && (py <= 11'd480) && in_circle)
        data_in = GREEN_PIX;
    // 眩光：横贯整幅画面的白色带（颜色分割判不出绿 -> 在灯上打一个洞）
    if(glare_on && (py >= GLARE_T) && (py <= GLARE_B))
        data_in = GLARE_PIX;
end

//-------------------------------------------------------
// 被测模块
//-------------------------------------------------------
armor_vision #(
    .IMG_W       (800        ),
    .IMG_H       (480        ),
    .AW          (10         ),
    .MORPH_N     (9          ),
    .CLK_FREQ    (25_000_000 ),
    .TH_G_DEF    (8'd100     ),
    .TH_GR_DEF   (8'd32      ),
    .TH_GB_DEF   (8'd32      ),
    .REL_SAT_PCT (8'd20      ),
    .TH_MIN      (4          ),
    .MIN_SIZE    (24         ),
    .AIM_H_Q8    (8'd64      ),
    .RING_T      (2          ),
    .CROSS_L     (12         )
) u_armor_vision (
    .clk        (clk        ),
    .rst_n      (rst_n      ),
    .vsync      (vsync      ),
    .de         (de         ),
    .data_in    (data_in    ),
    .key        (key        ),
    .data_out   (data_out   ),
    .led        (led        ),
    .seg_sel    (seg_sel    ),
    .seg_led    (seg_led    ),
    .bond_valid (bond_valid ),
    .center_x   (center_x   ),
    .center_y   (center_y   ),
    .aim_x      (aim_x      ),
    .aim_y      (aim_y      ),
    .uart_rxd   (1'b1       ),
    .uart_txd   (           )
);


//-------------------------------------------------------
// P0：fps 逻辑的独立验证实例
//   vision_stat 的 fps 要「1 秒窗口」才有输出，仿真里不可能真跑 1 秒。
//   这里用 CLK_FREQ = 2*(H_TOTAL*V_TOTAL) 再造一个实例：窗口正好等于 2 个帧周期
//   -> fps 应恒为 2，可以精确断言（比断言 1 强，能排除「计数器卡住」的巧合）。
//-------------------------------------------------------
wire [31:0] t_frame_cyc  ;
wire [15:0] t_fps        ;
wire [15:0] t_frame_lines;
wire [31:0] t_mask_cnt   ;
wire [15:0] t_hit_frames ;
wire [15:0] t_miss_frames;
wire        t_frame_tick ;

vision_stat #(
    .CLK_FREQ (2*1056*525)              // 窗口 = 2 个帧周期 -> fps 恒为 2
) u_vision_stat_test (
    .clk         (clk                    ),
    .rst_n       (rst_n                  ),
    .vsync       (vsync                  ),
    .de          (u_armor_vision.de_v    ),
    .mask        (u_armor_vision.mask_d  ),
    .bond_valid  (bond_valid             ),
    .frame_cyc   (t_frame_cyc            ),
    .fps         (t_fps                  ),
    .frame_lines (t_frame_lines          ),
    .mask_cnt    (t_mask_cnt             ),
    .hit_frames  (t_hit_frames           ),
    .miss_frames (t_miss_frames          ),
    .frame_tick  (t_frame_tick           )
);

//-------------------------------------------------------
// 抓取样点（用模块内部的像素坐标对齐，最稳）
//-------------------------------------------------------
always @(posedge clk) begin
    if(rst_n && u_armor_vision.de_v && (frame_cnt >= 32'd4)) begin
        // 圆内、不在环/十字上（注意：眩光带会盖住这一行）
        if((u_armor_vision.x_v == 10'd350) && (u_armor_vision.y_cnt == 10'd248))
            cap_in   <= data_out;
        // 远处背景
        if((u_armor_vision.x_v == 10'd100) && (u_armor_vision.y_cnt == 10'd400))
            cap_bg   <= data_out;
        // 圆环上（dx = 99，落在 97..101 环带内）
        if((u_armor_vision.x_v == 10'd507) && (u_armor_vision.y_cnt == 10'd248))
            cap_ring <= data_out;
        // 圆心（现在这里不再画十字，应该显示原色）
        if((u_armor_vision.x_v == 10'd408) && (u_armor_vision.y_cnt == 10'd248))
            cap_cctr <= data_out;
        // 瞄准点（py=199，不在眩光带内）
        if((u_armor_vision.x_v == 10'd408) && (u_armor_vision.y_cnt == 10'd199))
            cap_aim  <= data_out;
    end
end

//-------------------------------------------------------
// 检查任务
//-------------------------------------------------------
task chk;
    input [8*16-1:0] name;
    input [31:0]     got;
    input [31:0]     exp;
    begin
        if(got === exp)
            $display("  [OK]   %0s = %0d (0x%h)", name, got, got);
        else begin
            err_cnt = err_cnt + 32'd1;
            $display("  [FAIL] %0s = %0d (0x%h), expect %0d (0x%h)",
                     name, got, got, exp, exp);
        end
    end
endtask

// 相对等待 n 帧
// 邻近检查：团块跟踪报的是**全部亮像素的真实外延**，而旧的直方图投影有
// TH_MIN=4 的裁剪（边界上只有 1~3 个亮像素的列会被丢掉），所以边界会差 1~2 像素。
// 这不是错误，而是定义变了：现在报的是真实范围。中心/有效性仍然精确比较。
task chk_near;
    input [8*16-1:0] name;
    input [31:0]     got;
    input [31:0]     exp;
    input [31:0]     tol;
    reg   [31:0]     dlo;
    begin
        dlo = (got > exp) ? (got - exp) : (exp - got);
        if(dlo <= tol)
            $display("  [OK]   %0s = %0d (expect %0d +-%0d)", name, got, exp, tol);
        else begin
            err_cnt = err_cnt + 32'd1;
            $display("  [FAIL] %0s = %0d, expect %0d +-%0d", name, got, exp, tol);
        end
    end
endtask

// 区间检查：像掩码像素数这种值不适合精确比较（闭运算会略微填补离散化的阶梯）
task chk_range;
    input [8*16-1:0] name;
    input [31:0]     got;
    input [31:0]     lo;
    input [31:0]     hi;
    begin
        if((got >= lo) && (got <= hi))
            $display("  [OK]   %0s = %0d in [%0d, %0d]", name, got, lo, hi);
        else begin
            err_cnt = err_cnt + 32'd1;
            $display("  [FAIL] %0s = %0d NOT in [%0d, %0d]", name, got, lo, hi);
        end
    end
endtask

task wait_frames;
    input [31:0] n;
    reg   [31:0] tgt;
    begin
        tgt = frame_cnt + n;
        wait(frame_cnt >= tgt);
        repeat(200) @(posedge clk);
    end
endtask

// 按一次键：按住 >20ms 消抖，再松开 >20ms 让消抖器复位
task press_key;
    input [2:0] idx;
    begin
        key[idx] = 1'b0;
        repeat(530000) @(posedge clk);   // 21.2ms
        key[idx] = 1'b1;
        repeat(530000) @(posedge clk);   // 21.2ms
    end
endtask

//-------------------------------------------------------
// 主流程
//-------------------------------------------------------
//-------------------------------------------------------
// P4 单元测试：单独驱动 track_ab，验证门控 + 持久性 + 丢失撤销
//   （主实例里 TRK_EN=0 走逐帧路径，所以必须另起一个实例才能测到跟踪逻辑）
//-------------------------------------------------------
reg         ta_v_in ;
reg  [9:0]  ta_cx_i, ta_cy_i, ta_ay_i;
reg         ta_vsync;
wire        ta_valid;
wire [9:0]  ta_cx_o, ta_cy_o, ta_ax_o, ta_ay_o;
wire [4:0]  ta_lost ;

track_ab #(
    .AW (10), .WIDTH(800), .HEIGHT(480),
    .GATE (96), .HIT_N (2), .LOST_N (6)
) u_track_test (
    .clk       (clk       ),
    .rst_n     (rst_n     ),
    .vsync     (ta_vsync  ),
    .raw_valid (ta_v_in   ),
    .raw_cx    (ta_cx_i   ),
    .raw_cy    (ta_cy_i   ),
    .raw_ay    (ta_ay_i   ),
    .valid     (ta_valid  ),
    .cx        (ta_cx_o   ),
    .cy        (ta_cy_o   ),
    .ax        (ta_ax_o   ),
    .ay        (ta_ay_o   ),
    .lost_cnt  (ta_lost   )
);

//  送一帧给 track_ab（把 rise / fall 两个边沿都造出来）
//
//  【关键】必须在**时钟下降沿**改变 ta_vsync。
//  如果写成 `ta_vsync = 1'b0; @(posedge clk);` 就是在 posedge 的同一时刻改输入，
//  TB 的阻塞赋值和 DUT 的 always @(posedge clk) 会在同一个 active 区域里竞争，
//  谁先执行是未定义的 —— 实测 DUT 有时看到旧值，vsync_fall 不产生、frame_end 不触发，
//  track_ab 的全部寄存器恒为 0，看起来像设计坏了，其实是测试台的问题。
//  在 negedge 改，离下一个 posedge 还有半个周期，建立时间充裕。
task ta_frame;
    input v;
    begin
        @(negedge clk);
        ta_v_in  = v;
        ta_vsync = 1'b1;
        repeat(4) @(posedge clk);
        @(negedge clk);
        ta_vsync = 1'b0;
        repeat(4) @(posedge clk);
    end
endtask

initial begin
    $display("=======================================================");
    $display(" tb_armor_vision : DART green circle vision pipeline");
    $display(" image: 800x480, green disk center (400,240) radius 100");
    $display("=======================================================");

    rst_n = 1'b0;
    repeat(20) @(posedge clk);
    rst_n = 1'b1;

    wait_frames(6);

    //=====================================================
    $display("---- phase 1 : clean image, default thresholds ----");
    //=====================================================
    chk("bond_valid", bond_valid           , 32'd1   );
    chk_near("bond_l",  u_armor_vision.bl    , EXP_L   , 32'd2);
    chk_near("bond_r",  u_armor_vision.br    , EXP_R   , 32'd2);
    chk_near("bond_t",  u_armor_vision.bt    , EXP_T   , 32'd2);
    chk_near("bond_b",  u_armor_vision.bb    , EXP_B   , 32'd2);
    chk_near("bond_w",  u_armor_vision.bond_w, EXP_W   , 32'd3);
    chk("center_x",   center_x             , EXP_CX  );
    chk("center_y",   center_y             , EXP_CY  );
    chk("aim_x",      aim_x                , EXP_CX  );
    chk_near("aim_y",   aim_y              , EXP_AY  , 32'd2);
    chk_near("cent_x",  u_armor_vision.cent_x, EXP_CX, 32'd3);
    chk_near("cent_y",  u_armor_vision.cent_y, EXP_CY, 32'd3);
    //  填充率：半径 100 的圆 -> area/(w*h) 约 31417/39601 = 0.793 -> fill_q8 约 203
    chk_range("fill_q8", u_armor_vision.fill_q8, 32'd185, 32'd215);
    chk("blob_cnt",     u_armor_vision.blob_cnt, 32'd1);
    chk("blob_area>0",  (u_armor_vision.blob_area > 32'd20000), 32'd1);
    chk("th_g",       u_armor_vision.th_g  , 32'd100 );
    chk("th_gr",      u_armor_vision.th_gr , 32'd32  );
    chk("th_gb",      u_armor_vision.th_gb , 32'd32  );
    chk("sel",        u_armor_vision.sel   , 32'd0   );

    $display("---- phase 1 : pixel checks ----");
    chk("inside_green", cap_in , GREEN_PIX );   // 圆内保持原色
    chk("bg_dim",       cap_bg , DIM_PIX   );   // 圆外变暗
    chk("ring_red",     cap_ring, MARK_PIX );   // 圆环
    chk("cctr_green",   cap_cctr, GREEN_PIX);   // 圆心不画十字了
    chk("aim_red",      cap_aim , MARK_PIX );   // 瞄准点十字

    $display("---- phase 1 : misc ----");
    chk("led3_detected", {31'b0,led[3]} , 32'd0 );   // 低电平点亮
    chk("seg_sel_act", (seg_sel != 6'b111111), 32'd1);

    //=====================================================
    $display("---- phase 2 : GLARE band across the lamp (py 225..255) ----");
    $display("     old run-based projection collapsed here (h~84, cy~190)");
    //=====================================================
    glare_on = 1'b1;
    wait_frames(4);
    chk("bond_valid", bond_valid           , 32'd1   );
    chk_near("bond_l", u_armor_vision.bl    , GLA_L   , 32'd3);
    chk_near("bond_r", u_armor_vision.br    , GLA_R   , 32'd3);
    chk_near("bond_w", u_armor_vision.bond_w, GLA_W   , 32'd4);
    chk_near("bond_t", u_armor_vision.bt    , EXP_T   , 32'd2);
    chk_near("bond_b", u_armor_vision.bb    , EXP_B   , 32'd2);
    chk("center_y",    center_y             , EXP_CY  );
    chk_near("aim_y",  aim_y                , EXP_AY  , 32'd2);

    glare_on = 1'b0;
    wait_frames(4);
    $display("---- phase 2 : glare removed, must recover ----");
    chk_near("bond_l",  u_armor_vision.bl, EXP_L   , 32'd2);
    chk("inside_green", cap_in           , GREEN_PIX);
    chk("ring_red",     cap_ring         , MARK_PIX );

    //=====================================================
    $display("---- phase 3 : key[0] x1 -> select TH_G-R ----");
    //=====================================================
    press_key(3'd0);
    wait_frames(4);
    chk("sel",        u_armor_vision.sel, 32'd1 );
    chk("bond_valid", bond_valid        , 32'd1 );

    //=====================================================
    $display("---- phase 4 : key[1] x2 -> TH_GR=48 > G-R(44) -> lost ----");
    //=====================================================
    press_key(3'd1);
    press_key(3'd1);
    wait_frames(4);
    chk("th_gr",      u_armor_vision.th_gr, 32'd48);
    chk("bond_valid", bond_valid          , 32'd0);
    chk("led3_blink", {31'b0,led[3]}, {31'b0,~u_armor_vision.hb});

    //=====================================================
    $display("---- phase 5 : key[2] x2 -> TH_GR back to 32 -> found ----");
    //=====================================================
    press_key(3'd2);
    press_key(3'd2);
    wait_frames(4);
    chk("th_gr",      u_armor_vision.th_gr, 32'd32);
    chk("bond_valid", bond_valid          , 32'd1 );
    chk("center_x",   center_x            , EXP_CX);
    //  团块跟踪报真实外延 -> 宽 201（旧投影被 TH_MIN=4 裁到 199）
    //  -> aim_y = 248 - 201*64/256 = 198，差 1 像素是定义变化，放宽容差
    chk_near("aim_y",   aim_y             , EXP_AY  , 32'd2);

    //=====================================================
    $display("---- phase 6 : key[0] x1 -> select TH_G-B ----");
    //=====================================================
    press_key(3'd0);
    wait_frames(4);
    chk("sel", u_armor_vision.sel, 32'd2);

    //=====================================================
    $display("---- phase 7 : key[3] x1 -> binary display mode ----");
    //=====================================================
    press_key(3'd3);
    wait_frames(4);
    chk("disp_bin", u_armor_vision.disp_bin, 32'd1 );
    chk("bin_white", cap_in, BIN_W);

    //=====================================================
    //=====================================================
    $display("---- phase 8 : vision_stat instrumentation (P0) ----");
    $display("     frame period = H_TOTAL*V_TOTAL = 1056*525 = 554400 clk");
    //=====================================================
    chk      ("frame_lines",   u_armor_vision.st_frame_lines , 32'd480    );
    chk      ("frame_cyc",     u_armor_vision.st_frame_cyc   , 32'd554400 );
    // 绿盘半径 100 -> 面积约 31417；闭运算会填补离散化阶梯，略微变大
    chk_range("mask_cnt",      u_armor_vision.st_mask_cnt    , 32'd30000, 32'd33000);
    chk      ("hit_frames!=0", (u_armor_vision.st_hit_frames  != 16'd0), 32'd1);
    chk      ("miss_frames!=0",(u_armor_vision.st_miss_frames != 16'd0), 32'd1);
    // 独立实例：窗口正好 2 个帧周期 -> fps 恒为 2，顺带再验一次 frame_lines
    chk      ("t_fps",         t_fps                         , 32'd2     );
    chk      ("t_frame_lines", t_frame_lines                 , 32'd480   );

    //=====================================================
    $display("---- phase 9 : track_ab unit test (P4) ----");
    //=====================================================
    ta_cx_i = 10'd400; ta_cy_i = 10'd240; ta_ay_i = 10'd190;
    ta_v_in = 1'b0; ta_vsync = 1'b0;
    repeat(8) @(posedge clk);

    //  连续 2 帧命中 -> HIT_N=2 -> valid 拉高
    ta_frame(1'b1);
    chk("ta_hit1_valid0", {31'b0, ta_valid}, 32'd0);   // 只命中 1 帧还不够
    ta_frame(1'b1);
    chk("ta_hit2_valid1", {31'b0, ta_valid}, 32'd1);
    chk_near("ta_cx", ta_cx_o, 32'd400, 32'd6);

    //  连续 3 帧丢失 -> 还没到 LOST_N=6 -> 保持有效（不跳变）
    ta_frame(1'b0);
    ta_frame(1'b0);
    ta_frame(1'b0);
    chk("ta_hold_valid",  {31'b0, ta_valid}, 32'd1);

    //  突然出现在 600（离预测位置 200 像素 > GATE=96）-> 被门控拒掉
    ta_cx_i = 10'd600;
    ta_frame(1'b1);
    chk("ta_gate_reject", {31'b0, ta_valid}, 32'd1);   // 仍然有效，但没被拉过去
    chk("ta_gate_lost",   {27'b0, ta_lost},  32'd4);
    chk_near("ta_not_jump", ta_cx_o, 32'd400, 32'd40);

    //  再丢 3 帧 -> 累计 7 >= LOST_N -> 撤销
    ta_cx_i = 10'd400;
    ta_frame(1'b0);
    ta_frame(1'b0);
    ta_frame(1'b0);
    chk("ta_drop_valid",  {31'b0, ta_valid}, 32'd0);

    if(err_cnt == 32'd0)
        $display("==== ALL CHECKS PASSED ====");
    else
        $display("==== %0d CHECK(S) FAILED ====", err_cnt);

    $finish;
end

endmodule
