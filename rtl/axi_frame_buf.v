//----------------------------------------------------------------------------------------
// Zynq PL frame buffer: 128-bit FIFO words over the 64-bit AXI3 PS HP0 port.
// One burst transfers C_BURST_WORDS 128-bit words as 2*C_BURST_WORDS AXI beats.
// C_BURST_WORDS defaults to 8 so AWLEN/ARLEN is 15 (the AXI3 16-beat limit).
//----------------------------------------------------------------------------------------
`timescale 1ns / 1ps
module axi_frame_buf #(
    parameter integer C_FRAME_WORDS = 48000,
    parameter integer C_BURST_WORDS = 8,
    parameter [31:0] C_PAGE0_BASE = 32'h1000_0000,
    parameter [31:0] C_PAGE1_BASE = 32'h1010_0000
)(
    input wire ui_clk,
    input wire rst_n,
    output wire startup_delay_done,
    input wire [127:0] wfifo_dout,
    input wire [9:0] wfifo_rcount,
    output reg wfifo_rden,
    output reg [127:0] rfifo_din,
    output reg rfifo_wren,
    input wire [9:0] rfifo_wcount,
    input wire wr_load,
    input wire rd_load,
    input wire ddr3_read_valid,
    output reg [31:0] m_axi_awaddr,
    output reg [5:0] m_axi_awid,
    output reg [3:0] m_axi_awlen,
    output reg [2:0] m_axi_awsize,
    output reg [1:0] m_axi_awburst,
    output wire [1:0] m_axi_awlock,
    output wire [3:0] m_axi_awcache,
    output wire [2:0] m_axi_awprot,
    output reg m_axi_awvalid,
    input wire m_axi_awready,
    output reg [5:0] m_axi_wid,
    output reg [63:0] m_axi_wdata,
    output reg [7:0] m_axi_wstrb,
    output reg m_axi_wlast,
    output reg m_axi_wvalid,
    input wire m_axi_wready,
    input wire [5:0] m_axi_bid,
    input wire [1:0] m_axi_bresp,
    input wire m_axi_bvalid,
    output reg m_axi_bready,
    output reg [31:0] m_axi_araddr,
    output reg [5:0] m_axi_arid,
    output reg [3:0] m_axi_arlen,
    output reg [2:0] m_axi_arsize,
    output reg [1:0] m_axi_arburst,
    output wire [1:0] m_axi_arlock,
    output wire [3:0] m_axi_arcache,
    output wire [2:0] m_axi_arprot,
    output reg m_axi_arvalid,
    input wire m_axi_arready,
    input wire [63:0] m_axi_rdata,
    input wire [5:0] m_axi_rid,
    input wire [1:0] m_axi_rresp,
    input wire m_axi_rvalid,
    input wire m_axi_rlast,
    output reg m_axi_rready,
    output reg axi_error
);

localparam [2:0] W_IDLE = 3'd0, W_AW = 3'd1, W_FETCH = 3'd2,
                 W_SEND_LO = 3'd3, W_SEND_HI = 3'd4, W_B = 3'd5;
localparam [1:0] R_IDLE = 2'd0, R_AR = 2'd1, R_DATA = 2'd2;
localparam [4:0] AXI_BURST_LAST = (2 * C_BURST_WORDS) - 1;
localparam [31:0] BURST_WORDS = C_BURST_WORDS;
localparam [9:0] BURST_WORDS_10 = C_BURST_WORDS;
localparam [9:0] RFIFO_LOW = 10'd896;
localparam [10:0] RESET_DELAY_CYCLES = 11'd1024;

assign m_axi_awlock = 2'b00;
assign m_axi_awcache = 4'b0011;
assign m_axi_awprot = 3'b000;
assign m_axi_arlock = 2'b00;
assign m_axi_arcache = 4'b0011;
assign m_axi_arprot = 3'b000;

// This is only a settling delay after PS reset release, not a DDR calibration
// detector. PS DDR must be initialized by the boot flow before PL accesses it.
reg [10:0] ready_count;
always @(posedge ui_clk or negedge rst_n) begin
    if (!rst_n)
        ready_count <= 11'd0;
    else if (ready_count < RESET_DELAY_CYCLES)
        ready_count <= ready_count + 11'd1;
end
assign startup_delay_done = (ready_count >= RESET_DELAY_CYCLES);

// Synchronize frame boundary pulses into the AXI clock domain.
reg wr_load_meta, wr_load_sync, wr_load_prev;
reg rd_load_meta, rd_load_sync, rd_load_prev;
always @(posedge ui_clk or negedge rst_n) begin
    if (!rst_n) begin
        wr_load_meta <= 1'b0; wr_load_sync <= 1'b0; wr_load_prev <= 1'b0;
        rd_load_meta <= 1'b0; rd_load_sync <= 1'b0; rd_load_prev <= 1'b0;
    end else begin
        wr_load_meta <= wr_load;
        wr_load_sync <= wr_load_meta;
        wr_load_prev <= wr_load_sync;
        rd_load_meta <= rd_load;
        rd_load_sync <= rd_load_meta;
        rd_load_prev <= rd_load_sync;
    end
end
wire wr_frame_start = wr_load_sync & ~wr_load_prev;
wire rd_frame_start = rd_load_sync & ~rd_load_prev;

// The writer toggles pages once per camera frame; the reader always reads the
// other page. The initial page is undefined until one full camera frame is stored.
reg wr_page;
always @(posedge ui_clk or negedge rst_n) begin
    if (!rst_n)
        wr_page <= 1'b0;
    else if (wr_frame_start)
        wr_page <= ~wr_page;
end
wire rd_page = ~wr_page;

// AXI3 write controller. Each FIFO word is fetched once then sent low 64 bits,
// followed by high 64 bits. VALID remains asserted until a real handshake.
reg [2:0] wstate;
reg [4:0] wbeat;
reg [31:0] w_word_off;
reg [127:0] w_word;
wire [31:0] w_burst_addr = (wr_page ? C_PAGE1_BASE : C_PAGE0_BASE) + (w_word_off << 4);

always @(posedge ui_clk or negedge rst_n) begin
    if (!rst_n) begin
        wstate <= W_IDLE;
        wbeat <= 5'd0;
        w_word_off <= 32'd0;
        w_word <= 128'd0;
        wfifo_rden <= 1'b0;
        m_axi_awaddr <= 32'd0;
        m_axi_awid <= 6'd0;
        m_axi_awlen <= 4'd15;
        m_axi_awsize <= 3'b011;
        m_axi_awburst <= 2'b01;
        m_axi_awvalid <= 1'b0;
        m_axi_wid <= 6'd0;
        m_axi_wdata <= 64'd0;
        m_axi_wstrb <= 8'hFF;
        m_axi_wlast <= 1'b0;
        m_axi_wvalid <= 1'b0;
        m_axi_bready <= 1'b0;
    end else begin
        wfifo_rden <= 1'b0;
        case (wstate)
            W_IDLE: begin
                m_axi_awvalid <= 1'b0;
                m_axi_wvalid <= 1'b0;
                m_axi_bready <= 1'b0;
                wbeat <= 5'd0;
                if (w_word_off >= C_FRAME_WORDS)
                    w_word_off <= 32'd0;
                else if (startup_delay_done && wfifo_rcount >= BURST_WORDS_10) begin
                    m_axi_awaddr <= w_burst_addr;
                    m_axi_awlen <= 4'd15;
                    m_axi_awvalid <= 1'b1;
                    wstate <= W_AW;
                end
            end
            W_AW: begin
                if (m_axi_awvalid && m_axi_awready) begin
                    m_axi_awvalid <= 1'b0;
                    wstate <= W_FETCH;
                end
            end
            W_FETCH: begin
                w_word <= wfifo_dout;
                m_axi_wdata <= wfifo_dout[63:0];
                m_axi_wstrb <= 8'hFF;
                m_axi_wlast <= 1'b0;
                m_axi_wvalid <= 1'b1;
                wfifo_rden <= 1'b1;
                wstate <= W_SEND_LO;
            end
            W_SEND_LO: begin
                if (m_axi_wvalid && m_axi_wready) begin
                    m_axi_wdata <= w_word[127:64];
                    m_axi_wlast <= (wbeat == AXI_BURST_LAST - 1);
                    wbeat <= wbeat + 1'b1;
                    wstate <= W_SEND_HI;
                end
            end
            W_SEND_HI: begin
                if (m_axi_wvalid && m_axi_wready) begin
                    m_axi_wlast <= 1'b0;
                    if (wbeat == AXI_BURST_LAST) begin
                        m_axi_wvalid <= 1'b0;
                        wbeat <= 5'd0;
                        wstate <= W_B;
                    end else begin
                        m_axi_wvalid <= 1'b0;
                        wbeat <= wbeat + 1'b1;
                        wstate <= W_FETCH;
                    end
                end
            end
            W_B: begin
                m_axi_bready <= 1'b1;
                if (m_axi_bvalid && m_axi_bready) begin
                    m_axi_bready <= 1'b0;
                    w_word_off <= w_word_off + BURST_WORDS;
                    wstate <= W_IDLE;
                end
            end
            default: wstate <= W_IDLE;
        endcase
        if (wr_frame_start)
            w_word_off <= 32'd0;
    end
end

// AXI3 read controller. Two 64-bit beats form one original 128-bit FIFO word.
reg [1:0] rstate;
reg [31:0] r_word_off;
reg [4:0] rbeat;
reg [63:0] r_word_lo;
reg r_half;
reg [4:0] restart_wait;
reg r_flush;
wire [31:0] r_burst_addr = (rd_page ? C_PAGE1_BASE : C_PAGE0_BASE) + (r_word_off << 4);

always @(posedge ui_clk or negedge rst_n) begin
    if (!rst_n) begin
        rstate <= R_IDLE;
        r_word_off <= 32'd0;
        rbeat <= 5'd0;
        r_word_lo <= 64'd0;
        r_half <= 1'b0;
        restart_wait <= 5'd0;
        r_flush <= 1'b0;
        m_axi_araddr <= 32'd0;
        m_axi_arid <= 6'd0;
        m_axi_arlen <= 4'd15;
        m_axi_arsize <= 3'b011;
        m_axi_arburst <= 2'b01;
        m_axi_arvalid <= 1'b0;
        m_axi_rready <= 1'b0;
        rfifo_din <= 128'd0;
        rfifo_wren <= 1'b0;
    end else begin
        rfifo_wren <= 1'b0;
        case (rstate)
            R_IDLE: begin
                m_axi_arvalid <= 1'b0;
                m_axi_rready <= 1'b0;
                if (restart_wait != 0) begin
                    restart_wait <= restart_wait - 1'b1;
                end else if (r_flush) begin
                    r_flush <= 1'b0;
                    r_word_off <= 32'd0;
                end else if (r_word_off >= C_FRAME_WORDS) begin
                    r_word_off <= 32'd0;
                end else if (startup_delay_done && ddr3_read_valid && rfifo_wcount < RFIFO_LOW) begin
                    m_axi_araddr <= r_burst_addr;
                    m_axi_arlen <= 4'd15;
                    m_axi_arvalid <= 1'b1;
                    rbeat <= 5'd0;
                    r_half <= 1'b0;
                    rstate <= R_AR;
                end
            end
            R_AR: begin
                if (m_axi_arvalid && m_axi_arready) begin
                    m_axi_arvalid <= 1'b0;
                    m_axi_rready <= 1'b1;
                    rstate <= R_DATA;
                end
            end
            R_DATA: begin
                if (m_axi_rvalid && m_axi_rready) begin
                    if (!r_flush) begin
                        if (!r_half) begin
                            r_word_lo <= m_axi_rdata;
                            r_half <= 1'b1;
                        end else begin
                            rfifo_din <= {m_axi_rdata, r_word_lo};
                            rfifo_wren <= 1'b1;
                            r_half <= 1'b0;
                        end
                    end
                    if (m_axi_rlast) begin
                        m_axi_rready <= 1'b0;
                        rstate <= R_IDLE;
                        rbeat <= 5'd0;
                        if (r_flush)
                            r_word_off <= 32'd0;
                        else
                            r_word_off <= r_word_off + BURST_WORDS;
                    end else begin
                        rbeat <= rbeat + 1'b1;
                    end
                end
            end
            default: rstate <= R_IDLE;
        endcase
        if (rd_frame_start) begin
            r_flush <= 1'b1;
            restart_wait <= 5'd16;
            if (rstate == R_IDLE)
                r_word_off <= 32'd0;
        end
    end
end

wire write_error = m_axi_bvalid && m_axi_bready && (m_axi_bresp != 2'b00 || m_axi_bid != 6'd0);
wire read_error = m_axi_rvalid && m_axi_rready && (m_axi_rresp != 2'b00 || m_axi_rid != 6'd0 || m_axi_rlast != (rbeat == AXI_BURST_LAST));
always @(posedge ui_clk or negedge rst_n) begin
    if (!rst_n)
        axi_error <= 1'b0;
    else if (write_error || read_error)
        axi_error <= 1'b1;
end

endmodule
