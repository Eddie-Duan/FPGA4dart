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
//  目标几何做成【可改】的：phase 10 缩小（模拟远灯），
//  phase 11 逐帧平移（测速度预测），静止相位用默认值 400/240/10000。
reg  [10:0] img_cx = 11'd400;
reg  [10:0] img_cy = 11'd240;
reg  [23:0] img_r2 = 24'd10000;

wire signed [11:0] dxc = $signed({1'b0,px}) - $signed({1'b0,img_cx});
wire signed [11:0] dyc = $signed({1'b0,py}) - $signed({1'b0,img_cy});
wire [23:0] d2c = dxc*dxc + dyc*dyc;
wire in_circle = (d2c <= img_r2);

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
    .AIM_H_Q8    (16'd64      ),
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
// 真实靶标参数（AIM_H_Q8 = 372）的验证实例
//   本靶标：打击点在灯心上方 80mm、灯直径 55mm -> 1.449 倍灯直径
//   仿真图：灯心 y=248、灯宽约 201px -> 偏移 = 201*372/256 = 292px
//   292 > 248，瞄准点必然跑到画面上方之外 -> 必须【饱和到 0】。
//   如果这里读到 1023 附近，就是无符号下溢回绕（十字会跳到画面底部）。
//-------------------------------------------------------
wire        real_valid;
wire [9:0]  real_cx, real_cy, real_ax, real_ay;

blob_track #(
    .WIDTH    (800     ),
    .HEIGHT   (480     ),
    .AW       (10      ),
    .MIN_AREA (400     )
) u_blob_real (
    .clk        (clk                    ),
    .rst_n      (rst_n                  ),
    .vsync      (vsync                  ),
    .de         (u_armor_vision.de_v    ),
    .x          (u_armor_vision.x_v     ),
    .y          (u_armor_vision.y_cnt   ),
    .mask       (u_armor_vision.mask_d  ),
    .aim_h_q8   (16'd372                ),
    .min_area_lo(32'd8                  ),
    .bond_valid (real_valid             ),
    .bond_l     (                       ),
    .bond_r     (                       ),
    .bond_t     (                       ),
    .bond_b     (                       ),
    .center_x   (real_cx                ),
    .center_y   (real_cy                ),
    .aim_x      (real_ax                ),
    .aim_y      (real_ay                ),
    .blob_area  (                       ),
    .blob_cnt   (                       ),
    .cent_x     (                       ),
    .cent_y     (                       ),
    .fill_q8    (                       )
);

//  对照组：同一个掩码，但把宽松档关掉（min_area_lo = 0）
//  -> 远处的 200 像素小灯必须【认不到】，证明灵敏度是新宽松档带来的
wire lo_valid;

blob_track #(
    .WIDTH    (800     ),
    .HEIGHT   (480     ),
    .AW       (10      ),
    .MIN_AREA (400     )
) u_blob_looff (
    .clk        (clk                    ),
    .rst_n      (rst_n                  ),
    .vsync      (vsync                  ),
    .de         (u_armor_vision.de_v    ),
    .x          (u_armor_vision.x_v     ),
    .y          (u_armor_vision.y_cnt   ),
    .mask       (u_armor_vision.mask_d  ),
    .aim_h_q8   (16'd64                 ),
    .min_area_lo(32'd0                  ),
    .bond_valid (lo_valid               ),
    .bond_l     (                       ),
    .bond_r     (                       ),
    .bond_t     (                       ),
    .bond_b     (                       ),
    .center_x   (                       ),
    .center_y   (                       ),
    .aim_x      (                       ),
    .aim_y      (                       ),
    .blob_area  (                       ),
    .blob_far   (                       ),
    .blob_cnt   (                       ),
    .cent_x     (                       ),
    .cent_y     (                       ),
    .fill_q8    (                       )
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
//-------------------------------------------------------
// P1/P2 单测：result_frame v2 帧（24 字节）+ UART 接收监视器
//   主实例每 TX_DIV=8 帧才发一次，测试台跑不到；这里用 TX_DIV=1 的独立实例，
//   把已知常量打包发出来，再逐字节核对（含校验和）。
//   校验和的期望值是在 Python 里【独立算】的，不是从收到的数据反推，
//   所以能真正验到打包逻辑。
//-------------------------------------------------------
reg  [15:0] rf_div  = 16'd0;
reg         rf_tick = 1'b0;
always @(posedge clk) begin
    if(!rst_n) begin rf_div <= 16'd0; rf_tick <= 1'b0; end
    else begin
        rf_div  <= (rf_div == 16'd4999) ? 16'd0 : (rf_div + 16'd1);
        rf_tick <= (rf_div == 16'd4999);
    end
end

wire rf_txd;

result_frame #(
    .CLK_FREQ (25_000_000),
    .BAUD     (115200    ),
    .TX_DIV   (1         )
) u_rf_test (
    .clk        (clk       ),
    .rst_n      (rst_n     ),
    .frame_tick (rf_tick   ),
    .valid      (1'b1      ),
    .cx         (10'd408   ),
    .cy         (10'd248   ),
    .ax         (10'd408   ),
    .ay         (10'd198   ),
    .bw         (11'd201   ),
    .area       (32'd32000 ),
    .fill_q8    (8'd200    ),
    .blob_cnt   (3'd1      ),
    .adapt_ok   (1'b1      ),
    .disp_bin   (1'b0      ),
    .pred_ok    (1'b1      ),
    .moving     (1'b1      ),
    .far_small  (1'b0      ),
    .vx_q4      (16'sd96   ),   // 6.0 px/帧
    .vy_q4      (16'sd0    ),
    .px         (10'd440   ),
    .py         (10'd248   ),
    //  P11 弹道字段：w=201 -> dist=70cm drop=22px（表值，见 tools/gen_ballistic_lut.py）
    .dist_ok    (1'b1      ),
    .dist_cm    (16'd505   ),
    .drop_px    (16'd159   ),
    .fx         (10'd408   ),
    .fy         (10'd178   ),
    .txd        (rf_txd    )
);

//  ---- P11 弹道单测 ----
//  宽度 -> 距离 / 下坠 / 最终瞄准点；表值由 tools/gen_ballistic_lut.py 算出
reg         bl_vsync = 1'b0;
reg  [10:0] bl_bw    = 11'd100;
reg  [9:0]  bl_pcx   = 10'd300;
reg  [9:0]  bl_pcy   = 10'd248;
reg  [7:0]  bl_scale = 8'd255;      // 255 = x1.0（基准弹速 20m/s）
wire [15:0] bl_d_cm, bl_d_px;
wire [9:0]  bl_fx, bl_fy;
wire        bl_ok_t;

ballistic #(.AW(10), .WIDTH(800), .HEIGHT(480)) u_bal_test (
    .clk        (clk      ),
    .rst_n      (rst_n    ),
    .vsync      (bl_vsync ),
    .en         (1'b1     ),
    .raw_valid  (1'b1     ),
    .bw         (bl_bw    ),
    .aim_h_q8   (16'd64   ),
    .pcx        (bl_pcx   ),
    .pcy        (bl_pcy   ),
    .drop_scale (bl_scale ),
    .dist_cm    (bl_d_cm  ),
    .drop_px    (bl_d_px  ),
    .fx         (bl_fx    ),
    .fy         (bl_fy    ),
    .dist_ok    (bl_ok_t  )
);

//  ---- P12 多帧累积单测（8x4 小尺寸，清空只要 32 拍）----
reg         ta2_de   = 1'b0;
reg  [2:0]  ta2_x    = 3'd0;
reg  [2:0]  ta2_y    = 3'd0;
reg         ta2_mask = 1'b0;
reg         ta2_clr  = 1'b0;
wire [2:0]  ta2_xo, ta2_yo;
wire        ta2_deo, ta2_masko;

temporal_acc #(.WIDTH(8), .HEIGHT(4), .AW(3)) u_tacc_test (
    .clk     (clk      ),
    .rst_n   (rst_n    ),
    .de      (ta2_de   ),
    .x       (ta2_x    ),
    .y       (ta2_y    ),
    .mask_in (ta2_mask ),
    .en      (1'b1     ),
    .thr     (2'd2    ),
    .clr     (ta2_clr  ),
    .x_o     (ta2_xo   ),
    .y_o     (ta2_yo   ),
    .de_o    (ta2_deo  ),
    .mask_o  (ta2_masko)
);

//  115200 @ 25MHz = 217 拍/位；起始位下降沿后等 1.5 位再每 217 拍采一次
localparam integer UART_DIV = 217;
reg  [7:0]  ur_b [0:67];   // 收两帧（34x2）：第二帧验序号递增与 CRC
reg  [6:0]  ur_n    = 7'd0;
reg         ur_act  = 1'b0;
reg         ur_done = 1'b0;
reg  [15:0] ur_wait = 16'd0;
reg  [3:0]  ur_bs   = 4'd0;
reg  [7:0]  ur_sh   = 8'd0;
integer     uk;

//  ---- P12: 软件 CRC16/CCITT-FALSE，用来和硬件 CRC 对拍 ----
//  把 byte2..byte31 拼成 240 bit 逐位算；这样不依赖「第一帧 seq 一定是 0」的假设，
//  也能顺带指出「收到的字节序/覆盖范围」是否有错。
integer      uk2;
wire [239:0] ur_pay1 = { ur_b[2], ur_b[3], ur_b[4], ur_b[5], ur_b[6], ur_b[7], ur_b[8], ur_b[9], ur_b[10], ur_b[11], ur_b[12], ur_b[13], ur_b[14], ur_b[15], ur_b[16], ur_b[17], ur_b[18], ur_b[19], ur_b[20], ur_b[21], ur_b[22], ur_b[23], ur_b[24], ur_b[25], ur_b[26], ur_b[27], ur_b[28], ur_b[29], ur_b[30], ur_b[31] };
wire [239:0] ur_pay2 = { ur_b[36], ur_b[37], ur_b[38], ur_b[39], ur_b[40], ur_b[41], ur_b[42], ur_b[43], ur_b[44], ur_b[45], ur_b[46], ur_b[47], ur_b[48], ur_b[49], ur_b[50], ur_b[51], ur_b[52], ur_b[53], ur_b[54], ur_b[55], ur_b[56], ur_b[57], ur_b[58], ur_b[59], ur_b[60], ur_b[61], ur_b[62], ur_b[63], ur_b[64], ur_b[65] };
wire [15:0]  ur_c1   = { ur_b[32], ur_b[33] };
wire [15:0]  ur_c2   = { ur_b[66], ur_b[67] };

function [15:0] crc16_sw;
    input [239:0] dat;
    integer       i;
    reg   [15:0]  c;
    reg           msb;
    begin
        c = 16'hFFFF;
        for(i = 239; i >= 0; i = i - 1) begin
            msb = c[15] ^ dat[i];
            c   = {c[14:0], 1'b0} ^ (msb ? 16'h1021 : 16'h0000);
        end
        crc16_sw = c;
    end
endfunction

always @(posedge clk or negedge rst_n) begin
    if(!rst_n) begin
        ur_act <= 1'b0; ur_done <= 1'b0; ur_n <= 7'd0;
        ur_wait <= 16'd0; ur_bs <= 4'd0; ur_sh <= 8'd0;
    end
    else if(!ur_act) begin
        if(!ur_done && (rf_txd == 1'b0)) begin     // 起始位下降沿
            ur_act  <= 1'b1;
            ur_bs   <= 4'd0;
            ur_sh   <= 8'd0;
            ur_wait <= 16'd325;                    // 1.5 位 -> 采到 d0 中点
        end
    end
    else if(ur_wait == 16'd0) begin
        if(ur_bs < 4'd8) begin
            ur_sh   <= {rf_txd, ur_sh[7:1]};
            ur_bs   <= ur_bs + 4'd1;
            ur_wait <= 16'd216;                    // 每 217 拍一位
        end
        else begin                                 // 停止位 -> 收完一个字节
            if(ur_n < 7'd68) begin
                ur_b[ur_n] <= ur_sh;
                ur_n <= ur_n + 7'd1;
                if(ur_n == 7'd67) ur_done <= 1'b1;  // 收满两帧（68 字节）就冻结
            end
            ur_act <= 1'b0;
        end
    end
    else ur_wait <= ur_wait - 16'd1;
end

//  收到的帧自校验：byte2..byte22 异或 == byte23
function [7:0] ur_chk_calc;
    input        dmy;      // Verilog 要求函数至少一个输入
    integer      ck;
    begin
        ck = 0;
        for(uk = 2; uk <= 22; uk = uk + 1) ck = ck ^ ur_b[uk];
        ur_chk_calc = ck[7:0];
    end
endfunction

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
    .HIT_N (2), .LOST_N (6)
) u_track_test (
    .clk       (clk       ),
    .rst_n     (rst_n     ),
    .vsync     (ta_vsync  ),
    .gate      (10'd96    ),   // 门控半径改成运行时端口了
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

//  逐帧平移目标：在帧边界之后改 img_cx，避免和 posedge 抢同一个 active 区域
task move_target;
    input integer n;
    input integer dx;
    integer mk;
    begin
        for(mk = 0; mk < n; mk = mk + 1) begin
            wait_frames(1);
            img_cx = img_cx + dx;
        end
    end
endtask

//  给弹道单测打一拍 vsync（真实帧边界时序：下降沿后再等一拍才是 frame_end）
task bl_frame;
    begin
        @(negedge clk);
        bl_vsync = 1'b1;
        repeat(4) @(posedge clk);
        @(negedge clk);
        bl_vsync = 1'b0;
        repeat(4) @(posedge clk);
    end
endtask

//  给多帧累积单测喂一个像素：de 只拉高 1 拍，2 拍后看输出（BRAM 同步读 1 拍 + 判据 1 拍）
task ta2_px;
    input [2:0] px;
    input [2:0] py;
    input       pm;
    begin
        @(negedge clk);
        ta2_x = px; ta2_y = py; ta2_mask = pm; ta2_de = 1'b1;
        @(negedge clk);
        ta2_de = 1'b0;
        @(posedge clk);       // 像素在这个正沿被采样（读出 + 判据）
        @(negedge clk);       // 半个周期后读结果，避开与正沿的竞争
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
    //  真实靶标参数 372：圆心不变，但偏移 292px > 灯心 y -> 必须饱和到 0
    chk("real_bond_v",  real_valid         , 32'd1   );
    chk("real_center_y", real_cy           , EXP_CY  );
    chk("real_aim_x",    real_ax           , EXP_CX  );
    chk("real_aim_y_sat", real_ay          , 32'd0   );
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

    //=====================================================
    //  灵敏度相位：远处的【小绿灯】也必须被认出来
    //  旧代码：area < MIN_AREA(400) -> 最大的那块也被丢掉 -> valid=0，
    //  现场表现就是「屏幕上有高亮，但识别不到目标」。
    //  半径 8 的圆 -> 约 200 像素，落在新的【宽松档】(>= min_area_lo=8)
    //=====================================================
    $display("---- phase 10 : FAR / SMALL lamp (r=8, ~200 px) ----");
    img_r2 = 24'd64;
    wait_frames(3);
    chk("far_valid",  bond_valid, 32'd1);
    chk("far_flag",   {31'b0, u_armor_vision.raw_far}, 32'd1);
    chk_range("far_w", u_armor_vision.bond_w, 32'd12, 32'd22);
    chk_near("far_cx", center_x, 32'd408, 32'd3);
    chk_near("far_cy", center_y, 32'd248, 32'd3);
    //  同一个掩码再喂一个【宽松档关闭】的实例：必须回到旧行为（认不到小灯），
    //  证明「有绿灯就认」确实是新的宽松档在起作用，而不是别的地方整体松了
    chk("far_lo_off", {31'b0, lo_valid}, 32'd0);

    //=====================================================
    //  速度预测相位：目标 +6 px/帧 平移 8 帧
    //  期望：vx 收敛到约 6.0 px/帧（Q4 = 96）；提前量 = v*LEAD/16/256
    //  LEAD_Q4=64（4.0 帧）-> pd_cx 应比当前 center_x 超前 8~48 像素
    //=====================================================
    $display("---- phase 11 : MOVING lamp + velocity lead prediction ----");
    img_r2 = 24'd10000;
    img_cx = 11'd400;
    img_cy = 11'd240;
    wait_frames(3);
    chk("near_lo_off", {31'b0, lo_valid}, 32'd1);   // 大目标：严档照样认
    move_target(8, 6);
    chk("mov_pred_ok", {31'b0, u_armor_vision.pd_ok}, 32'd1);
    chk("mov_flag",    {31'b0, u_armor_vision.pd_mov}, 32'd1);
    chk("mov_vx_pos",  (u_armor_vision.pd_vx > 16'sd48), 32'd1);
    chk("mov_lead_dir",(u_armor_vision.pd_cx > center_x), 32'd1);
    chk_range("mov_lead_amt",
              {22'b0, u_armor_vision.pd_cx} - {22'b0, center_x}, 32'd8, 32'd48);
    chk("mov_ay_inside", (u_armor_vision.pd_ay <= center_y), 32'd1);
    img_cx = 11'd400;
    wait_frames(2);

    //=====================================================
    $display("---- phase 12 : result_frame v2 (24 bytes) over UART ----");
    //=====================================================
    wait(ur_done);
    repeat(20) @(posedge clk);
    chk("uart_nbytes", {25'd0, ur_n}, 32'd68);
    chk("uart_hdr0",   {24'd0, ur_b[0]},  32'hA5);
    chk("uart_hdr1",   {24'd0, ur_b[1]},  32'h5A);
    chk("uart_flags",  {24'd0, ur_b[2]},  32'hBB);   // 扩展帧+dist_ok+pred+moving+adapt+valid
    chk("uart_cx",     ({22'b0, ur_b[3]} << 8) | {24'd0, ur_b[4]}, 32'd408);
    chk("uart_cy",     ({22'b0, ur_b[5]} << 8) | {24'd0, ur_b[6]}, 32'd248);
    chk("uart_ay",     ({22'b0, ur_b[9]} << 8) | {24'd0, ur_b[10]}, 32'd198);
    chk("uart_w",      {24'd0, ur_b[11]}, 32'd201);
    chk("uart_area7",  {24'd0, ur_b[12]}, 32'd250);
    chk("uart_fill",   {24'd0, ur_b[13]}, 32'd200);
    chk("uart_vx",     ({22'b0, ur_b[15]} << 8) | {24'd0, ur_b[16]}, 32'd96);
    chk("uart_vy",     ({22'b0, ur_b[17]} << 8) | {24'd0, ur_b[18]}, 32'd0);
    chk("uart_px",     ({22'b0, ur_b[19]} << 8) | {24'd0, ur_b[20]}, 32'd440);
    chk("uart_py",     ({22'b0, ur_b[21]} << 8) | {24'd0, ur_b[22]}, 32'd248);
    //  P11 新增：距离 / 下坠 / 最终瞄准点
    chk("uart_dist",   ({22'b0, ur_b[23]} << 8) | {24'd0, ur_b[24]}, 32'd505);
    chk("uart_drop",   ({22'b0, ur_b[25]} << 8) | {24'd0, ur_b[26]}, 32'd159);
    chk("uart_fx",     ({22'b0, ur_b[27]} << 8) | {24'd0, ur_b[28]}, 32'd408);
    chk("uart_fy",     ({22'b0, ur_b[29]} << 8) | {24'd0, ur_b[30]}, 32'd178);
    //  帧序号：监视器抓到的第一帧未必是上电后第 0 帧，所以验「第二帧 = 第一帧 + 1」
    chk("uart_seq_inc", ({24'd0, ur_b[65]} - {24'd0, ur_b[31]}) & 32'hFF, 32'd1);
    chk("uart2_hdr0",   {24'd0, ur_b[34]}, 32'hA5);
    chk("uart2_hdr1",   {24'd0, ur_b[35]}, 32'h5A);
    //  CRC 用软件 CRC 对拍（覆盖 byte2..byte31），两帧都验
    chk("uart_crc_sw",  {16'd0, crc16_sw(ur_pay1)}, {16'd0, ur_c1});
    chk("uart2_crc_sw", {16'd0, crc16_sw(ur_pay2)}, {16'd0, ur_c2});
    $write("  raw_frame1:");
    for(uk2 = 0; uk2 < 34; uk2 = uk2 + 1) $write(" %02x", ur_b[uk2]);
    $write("\n  raw_frame2:");
    for(uk2 = 34; uk2 < 68; uk2 = uk2 + 1) $write(" %02x", ur_b[uk2]);
    $write("\n");

    //=====================================================
    //=====================================================
    $display("---- phase 13 : ballistic (distance + drop) unit test ----");
    //=====================================================
    //  宽度 100 -> 距离 141cm、下坠 45px；pcy=248 - (100*64/256=25) - 45 = 178
    bl_bw = 11'd100;
    bl_frame();
    chk("bal_ok",      {31'b0, bl_ok_t}, 32'd1);
    chk("bal_dist_w100", {16'd0, bl_d_cm}, 32'd141);
    chk("bal_drop_w100", {16'd0, bl_d_px}, 32'd45);
    chk("bal_fy_w100",   {22'd0, bl_fy},   32'd178);
    chk("bal_fx_w100",   {22'd0, bl_fx},   32'd300);

    //  宽度 201 -> 距离 70cm、下坠 22px；fy = 248 - 50 - 22 = 176
    bl_bw = 11'd201;
    bl_frame();
    chk("bal_dist_w201", {16'd0, bl_d_cm}, 32'd70);
    chk("bal_drop_w201", {16'd0, bl_d_px}, 32'd22);
    chk("bal_fy_w201",   {22'd0, bl_fy},   32'd176);

    //  弹速修正：写 163 (=25m/s, 164/256=0.64) -> 下坠 22*164/256 = 14
    bl_scale = 8'd163;
    bl_frame();
    chk("bal_drop_v25",  {16'd0, bl_d_px}, 32'd14);
    chk("bal_fy_v25",    {22'd0, bl_fy},   32'd184);
    bl_scale = 8'd255;

    //  主实例（灯宽 199~201）也要给出合理的距离/下坠：dist 69~72cm、drop 21~23px
    chk("main_dist_ok", {31'b0, u_armor_vision.bl_ok}, 32'd1);
    chk_range("main_dist", u_armor_vision.bl_dist_cm, 32'd69, 32'd72);
    chk_range("main_drop", u_armor_vision.bl_drop_px, 32'd21, 32'd23);

    //=====================================================
    $display("---- phase 14 : temporal_acc (P12) unit test ----");
    //=====================================================
    repeat(60) @(posedge clk);          // 等自动清空走完（8x4 = 32 拍）
    //  同一个像素：(2,1) 连亮两帧 -> acc=2 -> 被留下
    ta2_px(3'd2, 3'd1, 1'b1);
    chk("tacc_hit1", {31'b0, ta2_masko}, 32'd0);   // 只亮 1 帧：还不够
    ta2_px(3'd2, 3'd1, 1'b1);
    chk("tacc_hit2", {31'b0, ta2_masko}, 32'd1);   // 连中两帧：粘住
    chk("tacc_align_x", {29'd0, ta2_xo}, 32'd2);   // 坐标要跟着一起延 2 拍
    chk("tacc_align_y", {29'd0, ta2_yo}, 32'd1);
    chk("tacc_align_de", {31'b0, ta2_deo}, 32'd1);
    //  灯走了：一帧不亮 -> acc 回到 1 -> 又判为没有
    ta2_px(3'd2, 3'd1, 1'b0);
    chk("tacc_decay", {31'b0, ta2_masko}, 32'd0);
    //  噪声：另一个像素只亮 1 帧 -> 必须被拒绝（不会被攒成假目标）
    ta2_px(3'd5, 3'd2, 1'b1);
    chk("tacc_noise", {31'b0, ta2_masko}, 32'd0);
    chk("tacc_noise_x", {29'd0, ta2_xo}, 32'd5);
    //  再补一帧（(2,1) 第 3 次命中）：说明上一步「不亮」真的写回内存了
    ta2_px(3'd2, 3'd1, 1'b1);
    chk("tacc_persist", {31'b0, ta2_masko}, 32'd1);
    //  软件强制清零（0x0C bit7）：整块 RAM 真的被清掉，而不是只旁路一拍
    @(negedge clk); ta2_clr = 1'b1;
    @(negedge clk); ta2_clr = 1'b0;
    repeat(60) @(posedge clk);      // 8x4 = 32 拍清完
    ta2_px(3'd2, 3'd1, 1'b1);
    chk("tacc_clr_wipe", {31'b0, ta2_masko}, 32'd0);   // 清零前 acc=2
    ta2_px(3'd2, 3'd1, 1'b1);
    chk("tacc_clr_rehit", {31'b0, ta2_masko}, 32'd1);

    if(err_cnt == 32'd0)
        $display("==== ALL CHECKS PASSED ====");
    else
        $display("==== %0d CHECK(S) FAILED ====", err_cnt);

    $finish;
end

endmodule
