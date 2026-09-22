//****************************************Copyright (c)***********************************//
// File name:           tb_armor_vision
// Descriptions:        armor_vision 自检测试台（用 xsim 跑，不需要 DDR3 模型）
//
//   模拟场景：800x480、25MHz 像素时钟，时序与 39 工程的 LCD 读出时序相同
//     - 背景：灰 0x8410
//     - 左灯条：x = 200~219，y = 120~359（y = 200~204 故意挖 5 行缺口）
//     - 右灯条：x = 300~319，y = 120~359
//     - 小杂点：4x4 红块（验证栏投影阈值能滤掉）
//     - rddata 比 rdata_req 慢一拍（与 ddr3_fifo_ctrl 一致）
//
//   检查项目（共 20 项）：
//     1. 边界框位置：形态学让二值图往右下偏移 8，所以框应该贴在
//        x = 208~327、y = 128~367（= 灯条 + 8）
//     2. 中心：(267, 247)
//     3. 四种像素：灯条内(高亮原色)、缺口(被闭运算填起来)、
//        框外背景(变暗)、框线(绿色)
//     4. 第二阶段：换成蓝灯条 + 按 key[0] 切到蓝色模式，
//        验证按键消抖、模式切换与蓝色判据
//----------------------------------------------------------------------------------------
//****************************************************************************************//
`timescale 1ns / 1ps

module tb_armor_vision;

//-------------------------------------------------------
// 时序参数（与 lcd_driver.v 的 800x480 面板一致）
//-------------------------------------------------------
localparam H_TOTAL = 1056;
localparam H_SYNC  = 128 ;
localparam H_BACK  = 88  ;
localparam H_DISP  = 800 ;
localparam V_TOTAL = 525 ;
localparam V_SYNC  = 2   ;
localparam V_BACK  = 33  ;
localparam V_DISP  = 480 ;

localparam CLK_P   = 40;     // 25MHz 像素时钟

//-------------------------------------------------------
// 期望值
//-------------------------------------------------------
localparam EXP_L = 10'd208;
localparam EXP_R = 10'd327;
localparam EXP_T = 10'd128;
localparam EXP_B = 10'd367;
localparam EXP_CX= 10'd267;
localparam EXP_CY= 10'd247;

localparam RED_PIX  = 16'hF908;   // 红灯条
localparam BLU_PIX  = 16'h411F;   // 蓝灯条
localparam GRAY_PIX = 16'h8410;   // 背景灰
localparam DIM_PIX  = 16'h4208;   // 背景灰的变暗版
localparam BOX_PIX  = 16'h07E0;   // 框线绿

//reg define
reg         clk   = 1'b0;
reg         rst_n = 1'b0;
reg [10:0]  h_cnt = 11'd0;
reg [10:0]  v_cnt = 11'd0;
reg [3:0]   key   = 4'b1111;      // 不按
reg [15:0]  data_in;

//wire define
wire de     = (h_cnt >= (H_SYNC+H_BACK-2)) && (h_cnt < (H_SYNC+H_BACK+H_DISP-2))
           && (v_cnt >= (V_SYNC+V_BACK))   && (v_cnt < (V_SYNC+V_BACK+V_DISP));
wire vsync  = (h_cnt <= 11'd100) && (v_cnt == 11'd1);
wire [10:0] px = h_cnt - (H_SYNC+H_BACK-2);
wire [10:0] py = v_cnt - (V_SYNC+V_BACK) + 11'd1;

wire [15:0] data_out;
wire [3:0]  led;
wire        bond_valid;
wire [9:0]  center_x, center_y;

reg [31:0]  frame_cnt = 32'd0;
reg [15:0]  cap_bar, cap_gap, cap_bg, cap_border;
reg [31:0]  err_cnt = 32'd0;
reg         blue_phase = 1'b0;   // 1 = 改成蓝灯条（验证按键切模式）

//*****************************************************
//**                    main code
//*****************************************************

// 像素时钟
always #(CLK_P/2) clk = ~clk;

//-------------------------------------------------------
// 产生完整帧时序
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

    // 左灯条（中间挖 5 行缺口）
    if((px >= 200) && (px <= 219) && (py >= 120) && (py <= 359)
       && !((py >= 200) && (py <= 204)))
        data_in = blue_phase ? BLU_PIX : RED_PIX;

    // 右灯条
    if((px >= 300) && (px <= 319) && (py >= 120) && (py <= 359))
        data_in = blue_phase ? BLU_PIX : RED_PIX;

    // 小杂点（4x4）
    if((px >= 600) && (px <= 603) && (py >= 50) && (py <= 53))
        data_in = blue_phase ? BLU_PIX : RED_PIX;
end

//-------------------------------------------------------
// 待测模块
//-------------------------------------------------------
armor_vision #(
    .IMG_W     (800          ),
    .AW        (10           ),
    .MORPH_N   (9            ),
    .CLK_FREQ  (25_000_000   ),
    .LUM_MIN_SUM(150         ),
    .HIST_TH   (48           ),
    .BOX_THICK (3            )
) u_armor_vision (
    .clk        (clk        ),
    .rst_n      (rst_n      ),
    .vsync      (vsync      ),
    .de         (de         ),
    .data_in    (data_in    ),
    .key        (key        ),
    .data_out   (data_out   ),
    .led        (led        ),
    .bond_valid (bond_valid ),
    .center_x   (center_x   ),
    .center_y   (center_y   )
);

//-------------------------------------------------------
// 抓取四个测试像素（用模块内部对齐后的坐标，避免拍数对不上）
//-------------------------------------------------------
always @(posedge clk) begin
    if(rst_n && u_armor_vision.de_v && (frame_cnt >= 32'd6)) begin
        if((u_armor_vision.x_v == 10'd214) && (u_armor_vision.y_cnt == 10'd200))
            cap_bar    <= data_out;
        if((u_armor_vision.x_v == 10'd214) && (u_armor_vision.y_cnt == 10'd208))
            cap_gap    <= data_out;
        if((u_armor_vision.x_v == 10'd250) && (u_armor_vision.y_cnt == 10'd200))
            cap_bg     <= data_out;
        if((u_armor_vision.x_v == 10'd208) && (u_armor_vision.y_cnt == 10'd200))
            cap_border <= data_out;
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

//-------------------------------------------------------
// 主流程
//-------------------------------------------------------
initial begin
    $display("=======================================================");
    $display(" tb_armor_vision : armor plate vision pipeline test");
    $display(" image: 800x480, two red bars x=200..219 / 300..319, y=120..359");
    $display("=======================================================");

    rst_n = 1'b0;
    repeat(20) @(posedge clk);
    rst_n = 1'b1;

    // 等 8 帧（第 1 帧清直方图、第 2 帧算配对、第 3 帧开始出框）
    wait(frame_cnt >= 32'd8);
    repeat(200) @(posedge clk);

    $display("---- phase 1 : RED mode ----");
    chk("bond_valid", bond_valid         , 32'd1  );
    chk("bond_l",     u_armor_vision.bl  , EXP_L  );
    chk("bond_r",     u_armor_vision.br  , EXP_R  );
    chk("bond_t",     u_armor_vision.bt  , EXP_T  );
    chk("bond_b",     u_armor_vision.bb  , EXP_B  );
    chk("center_x",   center_x           , EXP_CX );
    chk("center_y",   center_y           , EXP_CY );

    $display("---- phase 1 : pixel checks ----");
    chk("bar_inside", cap_bar          , RED_PIX  );
    chk("bar_gap",    cap_gap          , GRAY_PIX );
    chk("bg_dim",     cap_bg           , DIM_PIX  );
    chk("box_border", cap_border       , BOX_PIX  );

    //=====================================================
    // phase 2：把靶纸换成蓝灯条，并按 key[0] 切到蓝色模式
    //=====================================================
    blue_phase = 1'b1;                 // 换成蓝灯条
    key[0]     = 1'b0;                 // 按住 key[0]（> 20ms 消抖时间）
    repeat(800000) @(posedge clk);     // 32ms
    key[0]     = 1'b1;                 // 放开
    repeat(400000) @(posedge clk);     // 16ms

    // 清掉第一阶段的取样值，确认第二阶段有重新取样
    cap_bar    = 16'd0;
    cap_gap    = 16'd0;
    cap_bg     = 16'd0;
    cap_border = 16'd0;

    wait(frame_cnt >= 32'd24);
    repeat(200) @(posedge clk);

    $display("---- phase 2 : BLUE mode (key[0] pressed) ----");
    chk("bond_valid", bond_valid         , 32'd1  );
    chk("bond_l",     u_armor_vision.bl  , EXP_L  );
    chk("bond_r",     u_armor_vision.br  , EXP_R  );
    chk("bond_t",     u_armor_vision.bt  , EXP_T  );
    chk("bond_b",     u_armor_vision.bb  , EXP_B  );
    chk("center_x",   center_x           , EXP_CX );
    chk("center_y",   center_y           , EXP_CY );
    chk("bar_inside", cap_bar            , BLU_PIX );
    chk("red_bar_gone", cap_bg           , DIM_PIX );

    if(err_cnt == 32'd0)
        $display("==== ALL CHECKS PASSED ====");
    else
        $display("==== %0d CHECK(S) FAILED ====", err_cnt);

    $finish;
end

endmodule
