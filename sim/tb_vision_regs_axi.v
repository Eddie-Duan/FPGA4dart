`timescale 1ns / 1ps
//============================================================================
// tb_vision_regs_axi.v
//   Self checking testbench for the A-line AXI4-Lite result register file.
//
//   Covers:
//     - reset values and the ID register
//     - SCRATCH read/write, including byte strobes
//     - IRQ_EN read/write
//     - vision -> AXI clock domain crossing: every payload field must land in
//       the matching register after one frame tick
//     - frame counter, W1C interrupt clear, SW_IRQ, CLR_CNT
//     - FPS window (SEC_CYCLES shortened to 200 cycles for simulation)
//     - unmapped address reads back 0
//
//   Run: sim\run_regs_sim.bat   (or xvlog/xelab/xsim by hand)
//============================================================================

module tb_vision_regs_axi;

    // shortened "one second" window: 200 AXI clocks (2 us at 100 MHz)
    localparam integer SEC = 200;

    // ------------------------------------------------------------------
    // clocks and resets
    // ------------------------------------------------------------------
    reg aclk = 1'b0;
    reg aresetn = 1'b0;
    reg res_clk = 1'b0;
    reg res_rst_n = 1'b0;

    always #5  aclk    = ~aclk;      // 100 MHz
    always #20 res_clk = ~res_clk;   // 25 MHz

    // ------------------------------------------------------------------
    // vision side stimuli
    // ------------------------------------------------------------------
    reg         frame_tick = 1'b0;
    reg         valid      = 1'b0;
    reg [9:0]   cx = 10'd0, cy = 10'd0, ax = 10'd0, ay = 10'd0;
    reg [10:0]  bw = 11'd0;
    reg [31:0]  area = 32'd0;
    reg [15:0]  dist_cm = 16'd0, drop_px = 16'd0;
    reg signed [15:0] vx_q4 = 16'sd0, vy_q4 = 16'sd0;
    reg [9:0]   px = 10'd0, py = 10'd0;
    reg [7:0]   fill_q8 = 8'd0;
    reg [2:0]   blob_cnt = 3'd0;
    reg [5:0]   flags = 6'd0;

    // ------------------------------------------------------------------
    // AXI4-Lite master
    // ------------------------------------------------------------------
    reg  [7:0]  awaddr  = 8'd0;
    reg         awvalid = 1'b0;
    wire        awready;
    reg  [31:0] wdata   = 32'd0;
    reg  [3:0]  wstrb   = 4'hF;
    reg         wvalid  = 1'b0;
    wire        wready;
    wire [1:0]  bresp;
    wire        bvalid;
    reg         bready  = 1'b0;

    reg  [7:0]  araddr  = 8'd0;
    reg         arvalid = 1'b0;
    wire        arready;
    wire [31:0] rdata;
    wire [1:0]  rresp;
    wire        rvalid;
    reg         rready  = 1'b0;

    wire        irq;

    // ------------------------------------------------------------------
    // DUT
    // ------------------------------------------------------------------
    vision_regs_axi #(
        .SEC_CYCLES (SEC)
    ) dut (
        .s_axi_aclk    (aclk),
        .s_axi_aresetn (aresetn),
        .s_axi_awaddr  (awaddr),
        .s_axi_awprot  (3'b000),
        .s_axi_awvalid (awvalid),
        .s_axi_awready (awready),
        .s_axi_wdata   (wdata),
        .s_axi_wstrb   (wstrb),
        .s_axi_wvalid  (wvalid),
        .s_axi_wready  (wready),
        .s_axi_bresp   (bresp),
        .s_axi_bvalid  (bvalid),
        .s_axi_bready  (bready),
        .s_axi_araddr  (araddr),
        .s_axi_arprot  (3'b000),
        .s_axi_arvalid (arvalid),
        .s_axi_arready (arready),
        .s_axi_rdata   (rdata),
        .s_axi_rresp   (rresp),
        .s_axi_rvalid  (rvalid),
        .s_axi_rready  (rready),
        .res_clk       (res_clk),
        .res_rst_n     (res_rst_n),
        .frame_tick    (frame_tick),
        .valid         (valid),
        .cx            (cx),
        .cy            (cy),
        .ax            (ax),
        .ay            (ay),
        .bw            (bw),
        .area          (area),
        .dist_cm       (dist_cm),
        .drop_px       (drop_px),
        .vx_q4         (vx_q4),
        .vy_q4         (vy_q4),
        .px            (px),
        .py            (py),
        .fill_q8       (fill_q8),
        .blob_cnt      (blob_cnt),
        .flags         (flags),
        .irq           (irq)
    );

    // ------------------------------------------------------------------
    // checking helpers
    // ------------------------------------------------------------------
    integer checks = 0;
    integer errors = 0;

    task chk;
        input integer id;
        input         cond;
        begin
            checks = checks + 1;
            if (cond !== 1'b1) begin
                errors = errors + 1;
                $display("  FAIL check %0d  (time %0t)", id, $time);
            end
        end
    endtask

    task chk_eq32;
        input integer id;
        input [31:0]  got;
        input [31:0]  exp;
        begin
            checks = checks + 1;
            if (got !== exp) begin
                errors = errors + 1;
                $display("  FAIL check %0d  got=0x%08X exp=0x%08X (time %0t)",
                         id, got, exp, $time);
            end
        end
    endtask

    // ------------------------------------------------------------------
    // AXI4-Lite transactions (driven on negedge to avoid races)
    // ------------------------------------------------------------------
    task axi_write;
        input [7:0]  addr;
        input [31:0] data;
        input [3:0]  strb;
        begin
            @(negedge aclk);
            awaddr = addr;  awvalid = 1'b1;
            wdata  = data;  wstrb = strb;  wvalid = 1'b1;
            @(posedge aclk);
            while (!(awready && wready)) @(posedge aclk);
            @(negedge aclk);
            awvalid = 1'b0;  wvalid = 1'b0;
            while (!bvalid) @(negedge aclk);
            bready = 1'b1;
            @(negedge aclk);
            bready = 1'b0;
            @(posedge aclk);
        end
    endtask

    task axi_read;
        input  [7:0]  addr;
        output [31:0] data;
        begin
            @(negedge aclk);
            araddr = addr;  arvalid = 1'b1;
            @(posedge aclk);
            while (!arready) @(posedge aclk);
            @(negedge aclk);
            arvalid = 1'b0;
            while (!rvalid) @(negedge aclk);
            data = rdata;
            rready = 1'b1;
            @(negedge aclk);
            rready = 1'b0;
            @(posedge aclk);
        end
    endtask

    // drive one frame worth of payload and pulse frame_tick (res_clk domain)
    task do_frame;
        input [9:0] c_x, c_y, a_x, a_y;
        begin
            @(negedge res_clk);
            cx = c_x;  cy = c_y;  ax = a_x;  ay = a_y;
            bw = 11'd321;
            area = 32'h00AB_CDEF;
            dist_cm = 16'd250;
            drop_px = 16'd17;
            vx_q4 = -16'sd48;
            vy_q4 =  16'sd96;
            px = c_x;  py = c_y;
            fill_q8 = 8'h80;
            blob_cnt = 3'd2;
            flags = 6'b101101;   // {disp_bin, far_small, moving, pred_ok, adapt_ok, dist_ok}
            valid = 1'b1;
            @(negedge res_clk);
            frame_tick = 1'b1;
            @(negedge res_clk);
            frame_tick = 1'b0;
            // let the toggle cross into the AXI domain (>= 2 aclk + margin)
            repeat (6) @(posedge aclk);
        end
    endtask

    // ------------------------------------------------------------------
    // test sequence
    // ------------------------------------------------------------------
    reg [31:0] rd;
    integer i;

    initial begin
        $display("==== tb_vision_regs_axi ====");

        repeat (4) @(posedge aclk);
        aresetn = 1'b1;
        repeat (4) @(posedge res_clk);
        res_rst_n = 1'b1;
        repeat (4) @(posedge aclk);

        // ---- 1..4 : reset values / ID ----
        axi_read(8'h00, rd);  chk_eq32(1, rd, 32'h5649_5331);  // ID
        axi_read(8'h10, rd);  chk_eq32(2, rd, 32'd0);          // SCRATCH reset
        axi_read(8'h14, rd);  chk_eq32(3, rd, 32'd0);          // FRAME_CNT reset
        axi_read(8'h0C, rd);  chk_eq32(4, rd, 32'd0);          // IRQ_STATUS reset
        chk(5, irq === 1'b0);                                   // no irq at reset

        // ---- 6..9 : SCRATCH read/write + byte strobes ----
        axi_write(8'h10, 32'hDEAD_BEEF, 4'hF);
        axi_read (8'h10, rd);  chk_eq32(6, rd, 32'hDEAD_BEEF);

        axi_write(8'h10, 32'h1122_3344, 4'hF);
        axi_write(8'h10, 32'h00AA_0000, 4'b0100);   // only byte 2
        axi_read (8'h10, rd);  chk_eq32(7, rd, 32'h11AA_3344);

        axi_write(8'h10, 32'h0000_0055, 4'b0001);   // only byte 0
        axi_read (8'h10, rd);  chk_eq32(8, rd, 32'h11AA_3355);

        // ---- 9..10 : IRQ_EN read/write ----
        axi_write(8'h08, 32'd1, 4'hF);
        axi_read (8'h08, rd);  chk_eq32(9, rd, 32'd1);
        axi_write(8'h08, 32'd0, 4'hF);
        axi_read (8'h08, rd);  chk_eq32(10, rd, 32'd0);

        // ---- 11..20 : frame 1 -> payload crosses into the AXI domain ----
        axi_write(8'h08, 32'd1, 4'hF);              // enable frame_done IRQ
        do_frame(10'd100, 10'd200, 10'd110, 10'd190);

        axi_read(8'h20, rd);  chk_eq32(11, rd, 32'd100);          // CX
        axi_read(8'h24, rd);  chk_eq32(12, rd, 32'd200);          // CY
        axi_read(8'h28, rd);  chk_eq32(13, rd, 32'd110);          // AX
        axi_read(8'h2C, rd);  chk_eq32(14, rd, 32'd190);          // AY
        axi_read(8'h30, rd);  chk_eq32(15, rd, 32'd321);          // BW
        axi_read(8'h34, rd);  chk_eq32(16, rd, 32'h00AB_CDEF);    // AREA
        axi_read(8'h38, rd);  chk_eq32(17, rd, 32'd250);          // DIST_CM
        axi_read(8'h3C, rd);  chk_eq32(18, rd, 32'd17);           // DROP_PX
        axi_read(8'h40, rd);  chk_eq32(19, rd, 32'hFFFF_FFD0);    // VX_Q4 = -48
        axi_read(8'h44, rd);  chk_eq32(20, rd, 32'd96);           // VY_Q4
        // FLAGS = {13'b0, blob_cnt=2, fill=0x80, 1'b0, flags=6'b101101, valid=1}
        axi_read(8'h1C, rd);  chk_eq32(21, rd, 32'h0002_805B);
        axi_read(8'h14, rd);  chk_eq32(22, rd, 32'd1);            // FRAME_CNT
        chk(23, irq === 1'b1);                                     // IRQ asserted

        // ---- 24..26 : W1C clears, counter keeps running ----
        axi_write(8'h0C, 32'd1, 4'hF);
        @(posedge aclk); @(posedge aclk);
        axi_read(8'h0C, rd);  chk_eq32(24, rd, 32'd0);
        chk(25, irq === 1'b0);
        axi_read(8'h14, rd);  chk_eq32(26, rd, 32'd1);

        // ---- 27..29 : IRQ disabled -> status still latches, irq stays low ---
        axi_write(8'h08, 32'd0, 4'hF);
        do_frame(10'd101, 10'd201, 10'd111, 10'd191);
        axi_read(8'h0C, rd);  chk_eq32(27, rd, 32'd1);   // frame_done latched
        chk(28, irq === 1'b0);                            // but masked
        axi_read(8'h14, rd);  chk_eq32(29, rd, 32'd2);    // counted anyway
        axi_write(8'h0C, 32'd1, 4'hF);                    // clear again

        // ---- 30..32 : SW_IRQ end-to-end ----
        axi_write(8'h08, 32'd1, 4'hF);                    // enable
        axi_write(8'h04, 32'd1, 4'hF);                    // CTRL.SW_IRQ
        @(posedge aclk); @(posedge aclk);
        chk(30, irq === 1'b1);
        axi_write(8'h0C, 32'd1, 4'hF);                    // W1C
        @(posedge aclk); @(posedge aclk);
        chk(31, irq === 1'b0);
        axi_read(8'h00, rd);  chk_eq32(32, rd, 32'h5649_5331);  // still alive

        // ---- 33..34 : CLR_CNT ----
        axi_write(8'h04, 32'd2, 4'hF);                    // CTRL.CLR_CNT
        @(posedge aclk); @(posedge aclk);
        axi_read(8'h14, rd);  chk_eq32(33, rd, 32'd0);
        chk(34, irq === 1'b0);

        // ---- 35..37 : FPS window (SEC = 200 aclk cycles) ----
        // 10 frames spaced ~ 10 res clocks apart = ~ 400 ns each => ~ 5 frames
        // inside one 2 us window; just require a sane non-zero rate.
        for (i = 0; i < 10; i = i + 1) begin
            do_frame(10'd100 + i[9:0], 10'd200, 10'd110, 10'd190);
        end
        repeat (SEC + 20) @(posedge aclk);
        axi_read(8'h18, rd);
        chk(35, (rd > 32'd0) && (rd < 32'd200));   // plausible fps, not garbage
        axi_read(8'h14, rd);
        chk(36, rd == 32'd10);                      // 10 frames counted
        axi_read(8'h1C, rd);
        chk_eq32(37, rd, 32'h0002_805B);            // last snapshot still valid

        // ---- 38..39 : unmapped address ----
        axi_read(8'h80, rd);  chk_eq32(38, rd, 32'd0);
        axi_read(8'hFC, rd);  chk_eq32(39, rd, 32'd0);
        chk(40, bresp === 2'b00);                    // OKAY response

        // ---- summary ----
        $display("----------------------------------------");
        if (errors == 0) begin
            $display("ALL CHECKS PASSED  (%0d checks)", checks);
        end else begin
            $display("FAILED: %0d of %0d checks", errors, checks);
        end
        $display("----------------------------------------");
        $finish;
    end

    // watchdog
    initial begin
        #2_000_000;
        $display("TIMEOUT");
        $finish;
    end

endmodule
