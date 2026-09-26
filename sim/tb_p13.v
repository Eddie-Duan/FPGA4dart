// tb_p13.v -- fast standalone unit test for P13a (syn_target) and P13c (lead table)
//
// WHY: the full vision testbench takes ~10 minutes. This one runs in seconds.
//
// CONTRACT of syn_target (as implemented):
//   * x / y are sampled at the rising edge; pix is registered (one clock later),
//     and the x comparison adds 1 to compensate, so "the pixel for coordinate x"
//     comes out one clock after x was presented -- reading it at the next negedge
//     gives exactly the value for that x.
//   * r2 tracks the radius register; row_t (= r2 - dy^2, signed) tracks y. Both are
//     registers, so after changing y or rad you must let a clock edge pass.
`timescale 1ns / 1ps

module tb_p13;

    reg clk   = 1'b0;
    reg rst_n = 1'b0;
    always #10 clk = ~clk;                 // 50 MHz

    integer err_cnt = 0;

    task chk;
        input [8*24-1:0] nm;
        input [31:0]     got;
        input [31:0]     exp;
        begin
            if(got === exp)
                $display("  [OK]   %0s = %0d", nm, got);
            else begin
                err_cnt = err_cnt + 1;
                $display("  [FAIL] %0s = %0d (0x%h), expect %0d (0x%h)", nm, got, got, exp, exp);
            end
        end
    endtask

    // ==========================================================
    // 1) syn_target
    // ==========================================================
    reg         sy_vsync = 1'b0;
    reg  [9:0]  sy_x     = 10'd0;
    reg  [9:0]  sy_y     = 10'd0;
    reg  [7:0]  sy_spd   = 8'd80;      // 5.0 px/frame
    reg  [9:0]  sy_rad   = 10'd60;
    wire [15:0] sy_pix;
    wire [9:0]  sy_cx;

    syn_target #(.AW(10), .WIDTH(800), .HEIGHT(480)) u_syn (
        .clk(clk), .rst_n(rst_n), .vsync(sy_vsync),
        .x(sy_x), .y(sy_y), .spd_q4(sy_spd), .rad(sy_rad),
        .pix(sy_pix), .cx(sy_cx)
    );

    //  feed one pixel and read its output: y is set one clock earlier than x, because
    //  row_t (= r2 - dy^2) is a register that needs a clock edge to follow a new line.
    reg [15:0] px_out;
    task syn_px;
        input [9:0] xx;
        input [9:0] yy;
        begin
            @(negedge clk);
            sy_y = yy;                 // 先让 y 稳定一拍（row_t 才能跟上新的一行）
            @(negedge clk);
            sy_x = xx;
            @(posedge clk);
            @(negedge clk);
            px_out = sy_pix;
        end
    endtask

    //  一帧边界：圆心按 spd_q4 移动
    task syn_frame;
        begin
            @(negedge clk); sy_vsync = 1'b1;
            @(negedge clk); sy_vsync = 1'b0;
            repeat(3) @(posedge clk);
        end
    endtask

    // ==========================================================
    // 2) aim_predict (only lead_used matters here)
    // ==========================================================
    reg         ap_vsync     = 1'b0;
    reg         ap_raw_valid = 1'b0;
    reg  [9:0]  ap_cx        = 10'd400;
    reg  [9:0]  ap_cy        = 10'd240;
    reg  [10:0] ap_bw        = 11'd100;
    reg  [15:0] ap_aim_h     = 16'd372;
    reg  [7:0]  ap_lead_man  = 8'd64;
    reg         ap_lead_auto = 1'b1;
    wire [9:0]  ap_pcx, ap_pcy, ap_pay;
    wire signed [15:0] ap_vx, ap_vy;
    wire        ap_ok, ap_mov;
    wire [7:0]  ap_lead;

    aim_predict #(.AW(10), .WIDTH(800), .HEIGHT(480)) u_ap (
        .clk(clk), .rst_n(rst_n), .vsync(ap_vsync),
        .en(1'b1), .raw_valid(ap_raw_valid),
        .cx(ap_cx), .cy(ap_cy), .bw(ap_bw), .aim_h_q8(ap_aim_h),
        .lead_q4(ap_lead_man), .lead_auto(ap_lead_auto),
        .pcx(ap_pcx), .pcy(ap_pcy), .pay(ap_pay),
        .vx_q4(ap_vx), .vy_q4(ap_vy), .pred_ok(ap_ok), .moving(ap_mov),
        .lead_used(ap_lead)
    );

    initial begin
        repeat(10) @(posedge clk);
        rst_n = 1'b1;
        repeat(10) @(posedge clk);

        $display("---- P13a syn_target (8x8 -> 800x480 raster) ----");
        //  圆心 (400,240)、半径 60；|dx| < 60 在里面，> 60 在外面
        syn_px(10'd400, 10'd240);
        chk("syn_center_green", {31'b0, (px_out == 16'h750E)}, 32'd1);
        chk("syn_cx_init",      {22'd0, sy_cx}, 32'd400);
        syn_px(10'd459, 10'd240);                 // 59 < 60 -> 圆内
        chk("syn_edge_in",      {31'b0, (px_out == 16'h750E)}, 32'd1);
        syn_px(10'd461, 10'd240);                 // 61 > 60 -> 圆外
        chk("syn_edge_out",     {31'b0, (px_out == 16'h7500)}, 32'd0);
        chk("syn_bg_gray",      {16'd0, px_out}, 32'h8410);
        syn_px(10'd400, 10'd302);                 // |302-240| = 62 > 60 -> 圆外（这一行一个像素都不该有）
        chk("syn_bg_gray_v",    {16'd0, px_out}, 32'h8410);
        syn_px(10'd400, 10'd240);

        //  每帧 +5px（spd_q4 = 80）
        syn_frame();  chk("syn_move_1", {22'd0, sy_cx}, 32'd405);
        syn_frame();  chk("syn_move_2", {22'd0, sy_cx}, 32'd410);
        syn_frame();  chk("syn_move_3", {22'd0, sy_cx}, 32'd415);
        //  反向速度（spd_q4 是 Q4：-5.0 px/帧 = -80 = 0xB0）
        sy_spd = 8'hB0;
        syn_frame();  chk("syn_move_neg", {22'd0, sy_cx}, 32'd410);
        sy_spd = 8'd80;
        //  半径可调：半径 100 -> x=500（dx=99）在圆内（r2 也是寄存器，要先跟上）
        sy_rad = 10'd100;
        repeat(3) @(posedge clk);
        syn_px(10'd500, 10'd240);
        chk("syn_radius_big",   {31'b0, (px_out == 16'h750E)}, 32'd1);

        $display("---- P13c lead table (3392.4 / w, auto) ----");
        ap_lead_auto = 1'b1; ap_raw_valid = 1'b1;
        ap_bw = 11'd100; repeat(3) @(posedge clk);
        chk("lead_w100", {24'd0, ap_lead}, 32'd34);      // 1.41m
        ap_bw = 11'd200; repeat(3) @(posedge clk);
        chk("lead_w200", {24'd0, ap_lead}, 32'd17);      // 0.71m -> 1.06 帧
        ap_bw = 11'd28;  repeat(3) @(posedge clk);
        chk("lead_w28",  {24'd0, ap_lead}, 32'd121);     // 5.05m -> 7.6 帧
        ap_bw = 11'd50;  repeat(3) @(posedge clk);
        chk("lead_w50",  {24'd0, ap_lead}, 32'd68);
        ap_lead_auto = 1'b0; repeat(3) @(posedge clk);
        chk("lead_manual", {24'd0, ap_lead}, 32'd64);
        ap_lead_auto = 1'b1; ap_bw = 11'd4; repeat(3) @(posedge clk);
        chk("lead_too_small", {24'd0, ap_lead}, 32'd64);  // 宽度不可信 -> 手动值

        if(err_cnt == 32'd0)
            $display("==== TB_P13 PASSED ====");
        else
            $display("==== TB_P13 %0d CHECK(S) FAILED ====", err_cnt);
        $finish;
    end

endmodule
