//****************************************************************************************//
// File name:           tb_probe
// Descriptions:        快速探针：只跑几帧，把显示通路上每一级的实际值打出来
//
//   用途：armor_vision 的像素出现 X 时，主测试台要跑 8 分钟才能看到结果，
//         而且看不到中间信号。这个台子只跑 4 帧（几十秒），并在固定坐标
//         把 draw / draw_p / on_ring / ring_t_eff / mask_d / img_d / disp_pix
//         全部 $display 出来，直接定位 X 从哪一级开始。
//
//   用法：xsim tb_probe -runall   （编译见 tools/ 里的说明，或直接 xvlog+xelab）
//****************************************************************************************//
`timescale 1ns / 1ps

module tb_probe;

localparam H_TOTAL = 1056, H_SYNC = 128, H_BACK = 88, H_DISP = 800;
localparam V_TOTAL = 525 , V_SYNC = 2  , V_BACK = 33, V_DISP = 480;
localparam CLK_P = 40;

reg         clk   = 1'b0;
reg         rst_n = 1'b0;
reg  [10:0] h_cnt = 11'd0;
reg  [10:0] v_cnt = 11'd0;
reg  [3:0]  key   = 4'b1111;
reg  [15:0] data_in;
reg  [31:0] frame_cnt = 32'd0;

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
wire [9:0]  center_x, center_y, aim_x, aim_y;

//  测试图：灰色背景 + 绿色实心圆（圆心 400,240 半径 100），和主测试台一致
wire signed [11:0] dxc = $signed({1'b0,px}) - 12'sd400;
wire signed [11:0] dyc = $signed({1'b0,py}) - 12'sd240;
wire [23:0] d2c = dxc*dxc + dyc*dyc;
always @(*) data_in = (d2c <= 24'd10000) ? 16'h750E : 16'h8410;

always #(CLK_P/2) clk = ~clk;

always @(posedge clk) begin
    if(!rst_n) begin h_cnt <= 11'd0; v_cnt <= 11'd0; end
    else if(h_cnt == H_TOTAL-1) begin
        h_cnt <= 11'd0;
        v_cnt <= (v_cnt == V_TOTAL-1) ? 11'd0 : (v_cnt + 11'd1);
    end
    else h_cnt <= h_cnt + 11'd1;
end

always @(posedge clk) if(rst_n && vsync && (h_cnt == 11'd0)) frame_cnt <= frame_cnt + 32'd1;

armor_vision #(
    .IMG_W (800), .IMG_H (480), .AW (10), .MORPH_N (9),
    .CLK_FREQ (25_000_000), .TH_G_DEF (8'd100), .TH_GR_DEF (8'd32), .TH_GB_DEF (8'd32),
    .REL_SAT_PCT (8'd20), .TH_MIN (4), .MIN_SIZE (24), .AIM_H_Q8 (16'd64),
    .RING_T (2), .CROSS_L (12)
) u_armor_vision (
    .clk (clk), .rst_n (rst_n), .vsync (vsync), .de (de), .data_in (data_in), .key (key),
    .data_out (data_out), .led (led), .seg_sel (seg_sel), .seg_led (seg_led),
    .bond_valid (bond_valid), .center_x (center_x), .center_y (center_y),
    .aim_x (aim_x), .aim_y (aim_y), .uart_rxd (1'b1), .uart_txd ()
);

integer n;
initial begin
    rst_n = 1'b0;
    repeat(20) @(posedge clk);
    rst_n = 1'b1;
    $display("[probe] 等 4 帧让管线稳定...");
    while(frame_cnt < 5) @(posedge clk);

    //  在 (350,248) —— 圆内（主测试台就是在这一点抓到 X 的）
    @(posedge clk);
    while(!(u_armor_vision.de_v && (u_armor_vision.x_v == 10'd350)
            && (u_armor_vision.y_cnt == 10'd248))) @(posedge clk);
    $display("[probe] ---- 采样点 (350,248) ----");
    $display("  ring_t_eff    = 0x%h", u_armor_vision.ring_t_eff);
    $display("  实例内部 ring_t = 0x%h   (X/Z = 端口没接上)",
             u_armor_vision.u_overlay_box.ring_t);
    $display("  rf_ring_t     = 0x%h   RING_T(param) = %0d",
             u_armor_vision.rf_ring_t, u_armor_vision.RING_T);
    $display("  reg_written   = %b", u_armor_vision.reg_written);
    $display("  bl/br/bt/bb   = %0d %0d %0d %0d",
             u_armor_vision.bl, u_armor_vision.br, u_armor_vision.bt, u_armor_vision.bb);
    $display("  on_ring/on_h/on_v = %b %b %b",
             u_armor_vision.u_overlay_box.on_ring,
             u_armor_vision.u_overlay_box.on_h,
             u_armor_vision.u_overlay_box.on_v);
    $display("  rr/r_in/r_ou  = %0d %0d %0d",
             u_armor_vision.u_overlay_box.rr, u_armor_vision.u_overlay_box.r_in,
             u_armor_vision.u_overlay_box.r_ou);
    $display("  w/h/rr        = %0d %0d %0d",
             u_armor_vision.u_overlay_box.w, u_armor_vision.u_overlay_box.h,
             u_armor_vision.u_overlay_box.rr);
    $display("  in2/out2/d2   = %0d %0d %0d",
             u_armor_vision.u_overlay_box.in2, u_armor_vision.u_overlay_box.out2,
             u_armor_vision.u_overlay_box.d2);
    $display("  draw / draw_p  = %b %b", u_armor_vision.draw, u_armor_vision.draw_p);
    $display("  pv_on(pd_mov) = %b   bl_fx/bl_fy = %0d %0d",
             u_armor_vision.pd_mov, u_armor_vision.bl_fx, u_armor_vision.bl_fy);
    $display("  osd_on        = %b   disp_bin = %b",
             u_armor_vision.osd_on, u_armor_vision.disp_bin);
    $display("  mask_d / img_d / dim = %b 0x%h 0x%h",
             u_armor_vision.mask_d, u_armor_vision.img_d, u_armor_vision.dim_pix);
    $display("  data_out      = 0x%h", data_out);
    $finish;
end

endmodule
