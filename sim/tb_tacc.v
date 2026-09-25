// tb_tacc.v -- standalone fast unit test for temporal_acc (P12)
//
// WHY: the full vision testbench takes ~8 minutes per run, far too slow to iterate
// on the accumulator's read/write pipeline. This one compiles and runs in seconds.
//
// THE CONTRACT (how temporal_acc is meant to be driven):
//   * de / x / y / mask_in are sampled at the rising edge: the pixel is whatever
//     value is present just before that edge.
//   * mask_o / x_o / y_o / de_o describe that same pixel, two clocks later, together.
// A sparse stream is fine -- de is the marker. The test drives one pixel per clock
// and samples in the middle of the cycle where de_o is high (no race with the edge).
`timescale 1ns / 1ps

module tb_tacc;

    reg clk   = 1'b0;
    reg rst_n = 1'b0;
    always #10 clk = ~clk;                  // 50 MHz

    reg        de      = 1'b0;
    reg  [2:0] x       = 3'd0;
    reg  [2:0] y       = 3'd0;
    reg        mask_in = 1'b0;
    reg        clr     = 1'b0;
    wire [2:0] x_o;
    wire [2:0] y_o;
    wire       de_o;
    wire       mask_o;

    integer err_cnt = 0;

    temporal_acc #(.WIDTH(8), .HEIGHT(4), .AW(3)) dut (
        .clk     (clk     ),
        .rst_n   (rst_n   ),
        .de      (de      ),
        .x       (x       ),
        .y       (y       ),
        .mask_in (mask_in ),
        .en      (1'b1    ),
        .thr     (2'd2    ),
        .clr     (clr     ),
        .x_o     (x_o     ),
        .y_o     (y_o     ),
        .de_o    (de_o    ),
        .mask_o  (mask_o  )
    );

    task chk;
        input [8*20-1:0] nm;
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

    //  present one pixel (de high across exactly one rising edge),
    //  then sample in the middle of the cycle where its outputs are valid
    task px;
        input [2:0] px_x;
        input [2:0] px_y;
        input       px_m;
        begin
            @(negedge clk);
            x = px_x; y = px_y; mask_in = px_m; de = 1'b1;
            @(negedge clk);
            de = 1'b0;
            @(posedge clk);      // sampling edge: BRAM read + judgement
            @(negedge clk);      // half a cycle later: no race with the edge
        end
    endtask

    initial begin
        repeat(10) @(posedge clk);
        rst_n = 1'b1;
        repeat(60) @(posedge clk);          // auto-clear (8x4 = 32 entries) finishes

        $display("---- temporal_acc unit test (8x4, thr = 2) ----");

        //  one lit frame is not enough
        px(3'd2, 3'd1, 1'b1);
        chk("hit1",     {31'b0, mask_o}, 32'd0);

        //  two lit frames stick
        px(3'd2, 3'd1, 1'b1);
        chk("hit2",     {31'b0, mask_o}, 32'd1);
        chk("align_x",  {29'd0, x_o   }, 32'd2);
        chk("align_y",  {29'd0, y_o   }, 32'd1);
        chk("align_de", {31'b0, de_o  }, 32'd1);

        //  lamp gone for one frame -> back below threshold
        px(3'd2, 3'd1, 1'b0);
        chk("decay",    {31'b0, mask_o}, 32'd0);

        //  a single-frame noise pixel somewhere else must be rejected
        px(3'd5, 3'd2, 1'b1);
        chk("noise",    {31'b0, mask_o}, 32'd0);
        chk("noise_x",  {29'd0, x_o   }, 32'd5);

        //  hitting (2,1) again: the "gone" frame really wrote back to the RAM
        px(3'd2, 3'd1, 1'b1);
        chk("persist",  {31'b0, mask_o}, 32'd1);

        //  software force-clear: the whole RAM must really be wiped (not just bypassed)
        @(negedge clk); clr = 1'b1;
        @(negedge clk); clr = 1'b0;
        repeat(60) @(posedge clk);      // 8x4 = 32 entries to walk through
        px(3'd2, 3'd1, 1'b1);
        chk("clr_wiped", {31'b0, mask_o}, 32'd0);   // had acc=2 before the clear
        px(3'd2, 3'd1, 1'b1);
        chk("clr_rehit", {31'b0, mask_o}, 32'd1);

        if(err_cnt == 32'd0)
            $display("==== TB_TACC PASSED ====");
        else
            $display("==== TB_TACC %0d CHECK(S) FAILED ====", err_cnt);
        $finish;
    end

endmodule
