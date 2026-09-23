//****************************************Copyright (c)***********************************//
// File name:           tb_armor_vision
// Descriptions:        armor_vision 自检测试台（xsim 直接跑，不需要 DDR3 模型）
//
//   模拟场景：800x480 @25MHz（和 39 例程的 LCD 时序相同）
//     - 背景：灰 0x8410
//     - 靶标：一个【绿色实心圆】，圆心 (400,240)、半径 100（原图坐标）
//             绿 = 0x750E -> r8=118  g8=162  b8=118
//             所以 G-R = 44、G-B = 44，正好可以用来验证 TH_G-R 阈值有没有生效
//     - rddata 与 rdata_req 打一拍（与 ddr3_fifo_ctrl 一致）
//
//   检查项：
//     相位 1  默认阈值：出框、圆心、边界框、以及 4 个采样点的像素
//             （圆内=原色、背景=变暗、圆环=红、圆心=红）
//     相位 2  key[0] 一次 -> 选中项切到 TH_G-R
//     相位 3  key[1] 两次 -> TH_G-R 32->48 > 44 -> 目标丢失（bond_valid=0）
//     相位 4  key[2] 两次 -> TH_G-R 回到 32 -> 恢复检测
//     相位 5  key[0] 一次 -> 选中项切到 TH_G-B
//     相位 6  key[3] 一次 -> 纯二值显示模式（圆内显示白色）
//
//   期望值的推导：
//     形态学窗口「右下角对齐」，膨胀+腐蚀后二值图整体往右下偏 8 像素，
//     所以二值图上的圆心是 (400+8, 240+8) = (408, 248)、半径仍是 100。
//     投影阈值 TH_MIN=24：一列的弦长 2*sqrt(100^2-d^2) >= 24 要求 |d| <= 99，
//     所以左右 = 408±99 = [309,507]、上下 = 248±99 = [149,347]（宽高都是 199）。
//     圆环半径 = (199+199)/4 = 99，环宽 ±2 -> 采样点取 (507,248)（dx=99，落在环上）。
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
// 合成图像：一个绿色实心圆
//-------------------------------------------------------
localparam CX_IMG = 400;
localparam CY_IMG = 240;
localparam RD2    = 10000;   // 100^2

//-------------------------------------------------------
// 期望值
//-------------------------------------------------------
localparam EXP_L  = 10'd309;
localparam EXP_R  = 10'd507;
localparam EXP_T  = 10'd149;
localparam EXP_B  = 10'd347;
localparam EXP_CX = 10'd408;
localparam EXP_CY = 10'd248;
localparam EXP_W  = 11'd199;

//-------------------------------------------------------
// 颜色
//-------------------------------------------------------
localparam GREEN_PIX = 16'h750E;   // 靶标绿（原色）
localparam GRAY_PIX  = 16'h8410;   // 背景灰
localparam DIM_PIX   = 16'h4208;   // 背景灰变暗后的值
localparam MARK_PIX  = 16'hF800;   // 标记红
localparam BIN_W     = 16'hFFFF;   // 纯二值模式：命中 = 白

//reg define
reg         clk   = 1'b0;
reg         rst_n = 1'b0;
reg  [10:0] h_cnt = 11'd0;
reg  [10:0] v_cnt = 11'd0;
reg  [3:0]  key   = 4'b1111;      // 全部松开
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

reg [31:0] frame_cnt = 32'd0;
reg [15:0] cap_in, cap_bg, cap_ring, cap_ctr;
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
// 合成测试图像
//-------------------------------------------------------
always @(*) begin
    data_in = GRAY_PIX;
    if((px <= 11'd799) && (py >= 11'd1) && (py <= 11'd480) && in_circle)
        data_in = GREEN_PIX;
end

//-------------------------------------------------------
// 被测模块
//-------------------------------------------------------
armor_vision #(
    .IMG_W     (800        ),
    .IMG_H     (480        ),
    .AW        (10         ),
    .MORPH_N   (9          ),
    .CLK_FREQ  (25_000_000 ),
    .TH_G_DEF  (8'd100     ),
    .TH_GR_DEF (8'd32      ),
    .TH_GB_DEF (8'd32      ),
    .TH_MIN    (24         ),
    .MIN_SIZE  (24         ),
    .RING_T    (2          ),
    .CROSS_L   (12         )
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
    .center_y   (center_y   )
);

//-------------------------------------------------------
// 抓取四个采样点（用模块内部的像素坐标对齐，最稳）
//-------------------------------------------------------
always @(posedge clk) begin
    if(rst_n && u_armor_vision.de_v && (frame_cnt >= 32'd4)) begin
        // 圆内（离圆心 58 像素，不在环/十字上）
        if((u_armor_vision.x_v == 10'd350) && (u_armor_vision.y_cnt == 10'd248))
            cap_in   <= data_out;
        // 远处背景
        if((u_armor_vision.x_v == 10'd100) && (u_armor_vision.y_cnt == 10'd400))
            cap_bg   <= data_out;
        // 圆环上（dx = 99，正好落在 [97,101] 环带内）
        if((u_armor_vision.x_v == 10'd507) && (u_armor_vision.y_cnt == 10'd248))
            cap_ring <= data_out;
        // 圆心
        if((u_armor_vision.x_v == 10'd408) && (u_armor_vision.y_cnt == 10'd248))
            cap_ctr  <= data_out;
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
    $display("---- phase 1 : default TH_G=100 TH_GR=32 TH_GB=32 ----");
    //=====================================================
    chk("bond_valid", bond_valid           , 32'd1   );
    chk("bond_l",     u_armor_vision.bl    , EXP_L   );
    chk("bond_r",     u_armor_vision.br    , EXP_R   );
    chk("bond_t",     u_armor_vision.bt    , EXP_T   );
    chk("bond_b",     u_armor_vision.bb    , EXP_B   );
    chk("bond_w",     u_armor_vision.bond_w, EXP_W   );
    chk("center_x",   center_x             , EXP_CX  );
    chk("center_y",   center_y             , EXP_CY  );
    chk("th_g",       u_armor_vision.th_g  , 32'd100 );
    chk("th_gr",      u_armor_vision.th_gr , 32'd32  );
    chk("th_gb",      u_armor_vision.th_gb , 32'd32  );
    chk("sel",        u_armor_vision.sel   , 32'd0   );

    $display("---- phase 1 : pixel checks ----");
    chk("inside_green", cap_in , GREEN_PIX );
    chk("bg_dim",       cap_bg , DIM_PIX   );
    chk("ring_red",     cap_ring, MARK_PIX );
    chk("center_red",   cap_ctr , MARK_PIX );

    $display("---- phase 1 : misc ----");
    chk("led3_on", {31'b0,led[3]}, 32'd0);     // 检测到时 led[3] 常亮
    chk("seg_sel_act", (seg_sel != 6'b111111), 32'd1);

    //=====================================================
    $display("---- phase 2 : key[0] x1 -> select TH_G-R ----");
    //=====================================================
    press_key(3'd0);
    wait_frames(4);
    chk("sel",        u_armor_vision.sel, 32'd1 );
    chk("bond_valid", bond_valid        , 32'd1 );

    //=====================================================
    $display("---- phase 3 : key[1] x2 -> TH_GR=48 > G-R(44) -> lost ----");
    //=====================================================
    press_key(3'd1);
    press_key(3'd1);
    wait_frames(4);
    chk("th_gr",      u_armor_vision.th_gr, 32'd48);
    chk("bond_valid", bond_valid          , 32'd0);
    chk("led3_blink", {31'b0,led[3]}, {31'b0,~u_armor_vision.hb});

    //=====================================================
    $display("---- phase 4 : key[2] x2 -> TH_GR back to 32 -> found ----");
    //=====================================================
    press_key(3'd2);
    press_key(3'd2);
    wait_frames(4);
    chk("th_gr",      u_armor_vision.th_gr, 32'd32);
    chk("bond_valid", bond_valid          , 32'd1 );
    chk("center_x",   center_x            , EXP_CX);

    //=====================================================
    $display("---- phase 5 : key[0] x1 -> select TH_G-B ----");
    //=====================================================
    press_key(3'd0);
    wait_frames(4);
    chk("sel", u_armor_vision.sel, 32'd2);

    //=====================================================
    $display("---- phase 6 : key[3] x1 -> binary display mode ----");
    //=====================================================
    press_key(3'd3);
    wait_frames(4);
    chk("disp_bin", u_armor_vision.disp_bin, 32'd1 );
    chk("bin_white", cap_in, BIN_W);

    //=====================================================
    if(err_cnt == 32'd0)
        $display("==== ALL CHECKS PASSED ====");
    else
        $display("==== %0d CHECK(S) FAILED ====", err_cnt);

    $finish;
end

endmodule
