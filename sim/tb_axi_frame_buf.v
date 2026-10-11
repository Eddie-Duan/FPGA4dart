`timescale 1ns / 1ps

module tb_axi_frame_buf;
    reg ui_clk = 1'b0;
    always #5 ui_clk = ~ui_clk;

    reg rst_n = 1'b0;
    reg read_enable = 1'b0;
    reg awready = 1'b0;
    reg wready = 1'b0;
    reg bvalid = 1'b0;
    reg arready = 1'b0;
    reg rvalid = 1'b0;
    reg rlast = 1'b0;
    reg [63:0] rdata = 64'd0;
    reg [5:0] rid = 6'd0;
    reg [1:0] rresp = 2'b00;
    reg [5:0] bid = 6'd0;
    reg [1:0] bresp = 2'b00;

    reg [127:0] fifo_words [0:7];
    integer fifo_read_idx = 0;
    reg [9:0] wfifo_rcount = 10'd8;
    wire [127:0] wfifo_dout = fifo_words[fifo_read_idx];
    wire wfifo_rden;

    wire [127:0] rfifo_din;
    wire rfifo_wren;
    reg [9:0] rfifo_wcount = 10'd0;
    wire startup_delay_done;
    wire axi_error;

    wire [31:0] awaddr;
    wire [5:0] awid;
    wire [3:0] awlen;
    wire [2:0] awsize;
    wire [1:0] awburst;
    wire [1:0] awlock;
    wire [3:0] awcache;
    wire [2:0] awprot;
    wire awvalid;
    wire [5:0] wid;
    wire [63:0] wdata;
    wire [7:0] wstrb;
    wire wlast;
    wire wvalid;
    wire bready;
    wire [31:0] araddr;
    wire [5:0] arid;
    wire [3:0] arlen;
    wire [2:0] arsize;
    wire [1:0] arburst;
    wire [1:0] arlock;
    wire [3:0] arcache;
    wire [2:0] arprot;
    wire arvalid;
    wire rready;

    axi_frame_buf #(
        .C_FRAME_WORDS(8)
    ) dut (
        .ui_clk(ui_clk),
        .rst_n(rst_n),
        .startup_delay_done(startup_delay_done),
        .wfifo_dout(wfifo_dout),
        .wfifo_rcount(wfifo_rcount),
        .wfifo_rden(wfifo_rden),
        .rfifo_din(rfifo_din),
        .rfifo_wren(rfifo_wren),
        .rfifo_wcount(rfifo_wcount),
        .wr_load(1'b0),
        .rd_load(1'b0),
        .ddr3_read_valid(read_enable),
        .m_axi_awaddr(awaddr),
        .m_axi_awid(awid),
        .m_axi_awlen(awlen),
        .m_axi_awsize(awsize),
        .m_axi_awburst(awburst),
        .m_axi_awlock(awlock),
        .m_axi_awcache(awcache),
        .m_axi_awprot(awprot),
        .m_axi_awvalid(awvalid),
        .m_axi_awready(awready),
        .m_axi_wid(wid),
        .m_axi_wdata(wdata),
        .m_axi_wstrb(wstrb),
        .m_axi_wlast(wlast),
        .m_axi_wvalid(wvalid),
        .m_axi_wready(wready),
        .m_axi_bid(bid),
        .m_axi_bresp(bresp),
        .m_axi_bvalid(bvalid),
        .m_axi_bready(bready),
        .m_axi_araddr(araddr),
        .m_axi_arid(arid),
        .m_axi_arlen(arlen),
        .m_axi_arsize(arsize),
        .m_axi_arburst(arburst),
        .m_axi_arlock(arlock),
        .m_axi_arcache(arcache),
        .m_axi_arprot(arprot),
        .m_axi_arvalid(arvalid),
        .m_axi_arready(arready),
        .m_axi_rdata(rdata),
        .m_axi_rid(rid),
        .m_axi_rresp(rresp),
        .m_axi_rvalid(rvalid),
        .m_axi_rlast(rlast),
        .m_axi_rready(rready),
        .axi_error(axi_error)
    );

    integer write_beat_count = 0;
    integer write_response_count = 0;
    integer read_beat_count = 0;
    integer read_word_count = 0;
    integer read_data_index = 0;
    reg read_active = 1'b0;
    reg held_aw_stall = 1'b0;
    reg [31:0] held_awaddr = 32'd0;
    reg held_w_stall = 1'b0;
    reg [63:0] held_wdata = 64'd0;
    reg held_wlast = 1'b0;

    always @(posedge ui_clk) begin
        if (!rst_n) begin
            fifo_read_idx <= 0;
            wfifo_rcount <= 10'd8;
            rfifo_wcount <= 10'd0;
            bvalid <= 1'b0;
            rvalid <= 1'b0;
            rlast <= 1'b0;
            read_active <= 1'b0;
            read_beat_count <= 0;
            read_word_count <= 0;
            write_beat_count <= 0;
            write_response_count <= 0;
            held_aw_stall <= 1'b0;
            held_w_stall <= 1'b0;
        end else begin
            if (wfifo_rden) begin
                fifo_read_idx <= fifo_read_idx + 1;
                wfifo_rcount <= wfifo_rcount - 1'b1;
            end

            if (held_aw_stall && (!awvalid || awaddr !== held_awaddr))
                $fatal(1, "AWVALID/address changed while AWREADY was low");
            held_aw_stall <= awvalid && !awready;
            held_awaddr <= awaddr;

            if (held_w_stall && (!wvalid || wdata !== held_wdata || wlast !== held_wlast))
                $fatal(1, "W channel changed while WREADY was low");
            held_w_stall <= wvalid && !wready;
            held_wdata <= wdata;
            held_wlast <= wlast;

            if (awvalid && awready) begin
                if (awaddr !== 32'h1000_0000 || awid !== 6'd0 ||
                    awlen !== 4'd15 || awsize !== 3'b011 || awburst !== 2'b01)
                    $fatal(1, "Unexpected AW transaction");
            end

            if (wvalid && wready) begin
                if (write_beat_count >= 16)
                    $fatal(1, "Unexpected extra write beat");
                if (wid !== 6'd0 || wstrb !== 8'hFF)
                    $fatal(1, "Unexpected WID/WSTRB");
                if ((write_beat_count[0] == 1'b0 &&
                     wdata !== fifo_words[write_beat_count / 2][63:0]) ||
                    (write_beat_count[0] == 1'b1 &&
                     wdata !== fifo_words[write_beat_count / 2][127:64]))
                    $fatal(1, "FIFO-to-AXI beat order mismatch at beat %0d", write_beat_count);
                if (wlast !== (write_beat_count == 15))
                    $fatal(1, "Incorrect WLAST at beat %0d", write_beat_count);
                write_beat_count <= write_beat_count + 1;
                if (write_beat_count == 15)
                    bvalid <= 1'b1;
            end

            if (bvalid && bready) begin
                bvalid <= 1'b0;
                write_response_count <= write_response_count + 1;
            end

            if (arvalid && arready) begin
                if (araddr !== 32'h1010_0000 || arid !== 6'd0 ||
                    arlen !== 4'd15 || arsize !== 3'b011 || arburst !== 2'b01)
                    $fatal(1, "Unexpected AR transaction");
                read_active <= 1'b1;
                read_beat_count <= 0;
            end

            if (read_active) begin
                if (!rvalid) begin
                    rdata <= read_data_index[0] ?
                        (64'hB000_0000_0000_0000 + read_data_index / 2) :
                        (64'hA000_0000_0000_0000 + read_data_index / 2);
                    rlast <= (read_data_index == 15);
                    rvalid <= 1'b1;
                    rresp <= 2'b00;
                    rid <= 6'd0;
                end else if (rready) begin
                    if (read_beat_count == 15) begin
                        rvalid <= 1'b0;
                        rlast <= 1'b0;
                        read_active <= 1'b0;
                    end else begin
                        read_beat_count <= read_beat_count + 1;
                        read_data_index <= read_data_index + 1;
                        rvalid <= 1'b0;
                    end
                end
            end

            if (rfifo_wren) begin
                if (rfifo_din !== {
                    64'hB000_0000_0000_0000 + read_word_count,
                    64'hA000_0000_0000_0000 + read_word_count
                })
                    $fatal(1, "AXI-to-FIFO word order mismatch at word %0d", read_word_count);
                read_word_count <= read_word_count + 1;
                rfifo_wcount <= rfifo_wcount + 1'b1;
            end
        end
    end

    initial begin
        for (integer i = 0; i < 8; i = i + 1)
            fifo_words[i] = {
                64'h1100_0000_0000_0000 + i,
                64'h2200_0000_0000_0000 + i
            };

        repeat (5) @(negedge ui_clk);
        rst_n = 1'b1;

        wait (startup_delay_done);
        wait (awvalid);
        repeat (3) @(negedge ui_clk);
        if (!awvalid || awaddr !== 32'h1000_0000)
            $fatal(1, "AWVALID did not remain asserted during backpressure");
        awready = 1'b1;
        @(negedge ui_clk);
        awready = 1'b0;

        wait (wvalid);
        repeat (3) @(negedge ui_clk);
        if (!wvalid || wdata !== fifo_words[0][63:0])
            $fatal(1, "WVALID/WDATA did not remain stable during backpressure");
        wready = 1'b1;
        wait (write_response_count == 1);
        if (write_beat_count != 16 || fifo_read_idx != 8)
            $fatal(1, "Write burst did not consume exactly eight FIFO words");
        if (axi_error)
            $fatal(1, "Unexpected AXI response error");

        read_enable = 1'b1;
        wait (arvalid);
        repeat (3) @(negedge ui_clk);
        if (!arvalid || araddr !== 32'h1010_0000)
            $fatal(1, "ARVALID did not remain asserted during backpressure");
        arready = 1'b1;
        @(negedge ui_clk);
        arready = 1'b0;

        wait (read_word_count == 8);
        read_enable = 1'b0;
        repeat (3) @(negedge ui_clk);
        if (read_word_count != 8 || axi_error)
            $fatal(1, "Read burst did not return eight valid FIFO words");

        $display("PASS: AXI3 64-bit burst handshakes, beat order, WLAST and FIFO packing");
        $finish;
    end

    initial begin
        #1000000;
        $fatal(1, "Simulation timeout");
    end
endmodule
