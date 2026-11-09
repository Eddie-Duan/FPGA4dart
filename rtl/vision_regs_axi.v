`timescale 1ns / 1ps
//============================================================================
// vision_regs_axi.v
//   A-line stage 1 : AXI4-Lite result register file + end-of-frame interrupt
//
//   PS side (s_axi_aclk = FCLK_CLK0, 100 MHz) reads a coherent snapshot of the
//   vision results.  The vision side (res_clk = lcd pixel clock, 25 MHz)
//   latches the payload once per frame and toggles a flag.  The toggle is
//   synchronized with 2 FFs into the AXI clock domain and its edge loads the
//   shadow registers.  The payload is stable for a whole frame (33 ms), so a
//   "data bus + toggle flag" handshake is safe here: the data is guaranteed
//   to be quiet for at least one full frame before and after the toggle.
//
//   Register map (byte offsets, 32-bit registers, 256 byte window)
//     0x00 ID          RO   0x56495331  ("VIS1")
//     0x04 CTRL        RW   bit0 = SW_IRQ   (write 1, self clearing)
//                           bit1 = CLR_CNT  (write 1, self clearing)
//     0x08 IRQ_EN      RW   bit0 = frame_done enable
//     0x0C IRQ_STATUS  W1C  bit0 = frame_done
//     0x10 SCRATCH     RW   32-bit scratch, proves the write path
//     0x14 FRAME_CNT   RO   frames seen since reset / CLR_CNT
//     0x18 FPS         RO   frames latched in the last ~1 s window
//     0x1C FLAGS       RO   [0]valid [1]dist_ok [2]pred_ok [3]adapt_ok
//                           [4]moving [5]far_small [6]disp_bin
//                           [15:8]fill_q8 [18:16]blob_cnt
//     0x20 CX     0x24 CY     0x28 AX     0x2C AY
//     0x30 BW     0x34 AREA   0x38 DIST_CM 0x3C DROP_PX
//     0x40 VX_Q4  0x44 VY_Q4  0x48 PX      0x4C PY
//
//   Notes
//     - All RW registers are byte strobe aware (WSTRB).
//     - IRQ is a level: irq = IRQ_EN[0] & IRQ_STATUS[0]; PS clears it with a
//       W1C write, which is what the dart video_manager driver expects.
//     - SEC_CYCLES is the number of s_axi_aclk cycles in the FPS window
//       (100_000_000 for a real 100 MHz clock; shorten it in simulation).
//============================================================================
`timescale 1ns / 1ps

module vision_regs_axi #(
    parameter integer C_S_AXI_DATA_WIDTH = 32,
    parameter integer C_S_AXI_ADDR_WIDTH = 8,
    parameter integer SEC_CYCLES         = 100_000_000
)(
    // ------------------------------------------------------------------
    // AXI4-Lite slave
    // ------------------------------------------------------------------
    input  wire                                s_axi_aclk,
    input  wire                                s_axi_aresetn,
    input  wire [C_S_AXI_ADDR_WIDTH-1:0]       s_axi_awaddr,
    input  wire [2:0]                          s_axi_awprot,
    input  wire                                s_axi_awvalid,
    output wire                                s_axi_awready,
    input  wire [C_S_AXI_DATA_WIDTH-1:0]       s_axi_wdata,
    input  wire [(C_S_AXI_DATA_WIDTH/8)-1:0]   s_axi_wstrb,
    input  wire                                s_axi_wvalid,
    output wire                                s_axi_wready,
    output wire [1:0]                          s_axi_bresp,
    output wire                                s_axi_bvalid,
    input  wire                                s_axi_bready,
    input  wire [C_S_AXI_ADDR_WIDTH-1:0]       s_axi_araddr,
    input  wire [2:0]                          s_axi_arprot,
    input  wire                                s_axi_arvalid,
    output wire                                s_axi_arready,
    output wire [C_S_AXI_DATA_WIDTH-1:0]       s_axi_rdata,
    output wire [1:0]                          s_axi_rresp,
    output wire                                s_axi_rvalid,
    input  wire                                s_axi_rready,
    // ------------------------------------------------------------------
    // vision side (res_clk domain, lcd pixel clock)
    // ------------------------------------------------------------------
    input  wire                                res_clk,
    input  wire                                res_rst_n,
    input  wire                                frame_tick,   // 1 clk pulse, once per frame
    input  wire                                valid,
    input  wire [9:0]                          cx,
    input  wire [9:0]                          cy,
    input  wire [9:0]                          ax,
    input  wire [9:0]                          ay,
    input  wire [10:0]                         bw,
    input  wire [31:0]                         area,
    input  wire [15:0]                         dist_cm,
    input  wire [15:0]                         drop_px,
    input  wire signed [15:0]                  vx_q4,
    input  wire signed [15:0]                  vy_q4,
    input  wire [9:0]                          px,
    input  wire [9:0]                          py,
    input  wire [7:0]                          fill_q8,
    input  wire [2:0]                          blob_cnt,
    // flags = {disp_bin, far_small, moving, pred_ok, adapt_ok, dist_ok}
    input  wire [5:0]                          flags,
    // ------------------------------------------------------------------
    output wire                                irq
);

    // ------------------------------------------------------------------
    // register offsets
    // ------------------------------------------------------------------
    localparam [5:0] REG_ID        = 6'h00;
    localparam [5:0] REG_CTRL      = 6'h01;
    localparam [5:0] REG_IRQ_EN    = 6'h02;
    localparam [5:0] REG_IRQ_STAT  = 6'h03;
    localparam [5:0] REG_SCRATCH   = 6'h04;
    localparam [5:0] REG_FRAME_CNT = 6'h05;
    localparam [5:0] REG_FPS       = 6'h06;
    localparam [5:0] REG_FLAGS     = 6'h07;
    localparam [5:0] REG_CX        = 6'h08;
    localparam [5:0] REG_CY        = 6'h09;
    localparam [5:0] REG_AX        = 6'h0A;
    localparam [5:0] REG_AY        = 6'h0B;
    localparam [5:0] REG_BW        = 6'h0C;
    localparam [5:0] REG_AREA      = 6'h0D;
    localparam [5:0] REG_DIST      = 6'h0E;
    localparam [5:0] REG_DROP      = 6'h0F;
    localparam [5:0] REG_VX        = 6'h10;
    localparam [5:0] REG_VY        = 6'h11;
    localparam [5:0] REG_PX        = 6'h12;
    localparam [5:0] REG_PY        = 6'h13;

    localparam [31:0] ID_VALUE = 32'h5649_5331;  // "VIS1"

    // ------------------------------------------------------------------
    // vision domain : snapshot + toggle
    //   [191:185] reserved (0)
    //   [184:174] bw        [173:142] area      [141:126] dist_cm
    //   [125:110] drop_px   [109:94]  vx_q4     [93:78]   vy_q4
    //   [77:68]   px        [67:58]   py        [57:50]   fill_q8
    //   [49:47]   blob_cnt  [46:41]   flags     [40]      valid
    //   [39:30]   cx        [29:20]   cy        [19:10]   ax
    //   [9:0]     ay
    // ------------------------------------------------------------------
    reg  [191:0] hold;
    reg          tog;

    always @(posedge res_clk or negedge res_rst_n) begin
        if (!res_rst_n) begin
            hold <= 192'd0;
            tog  <= 1'b0;
        end else if (frame_tick) begin
            hold <= {7'd0, bw, area, dist_cm, drop_px, vx_q4, vy_q4,
                     px, py, fill_q8, blob_cnt, flags, valid, cx, cy, ax, ay};
            tog  <= ~tog;
        end
    end

    // ------------------------------------------------------------------
    // AXI domain : toggle sync -> snapshot shadow + interrupt
    // ------------------------------------------------------------------
    reg  tog_s1, tog_s2, tick_axi;
    reg  [191:0] snap;
    reg  [31:0]  frame_cnt;
    reg  [15:0]  fps, fps_win;
    reg  [31:0]  sec_cnt;
    reg          irq_status;
    reg          irq_en;
    reg  [31:0]  scratch;
    reg          sw_irq;      // one cycle pulse from CTRL[0]
    reg          clr_cnt;     // one cycle pulse from CTRL[1]
    reg          w1c_irq;     // one cycle pulse from IRQ_STATUS write

    // 2-FF synchronizer + edge detect (the toggle flips once per frame)
    always @(posedge s_axi_aclk or negedge s_axi_aresetn) begin
        if (!s_axi_aresetn) begin
            tog_s1   <= 1'b0;
            tog_s2   <= 1'b0;
            tick_axi <= 1'b0;
        end else begin
            tog_s1   <= tog;
            tog_s2   <= tog_s1;
            tick_axi <= tog_s1 ^ tog_s2;
        end
    end

    // snapshot, frame counter, fps window, interrupt flag
    always @(posedge s_axi_aclk or negedge s_axi_aresetn) begin
        if (!s_axi_aresetn) begin
            snap       <= 192'd0;
            frame_cnt  <= 32'd0;
            fps        <= 16'd0;
            fps_win    <= 16'd0;
            sec_cnt    <= 32'd0;
            irq_status <= 1'b0;
        end else begin
            // 1 s window for FPS
            if (sec_cnt == (SEC_CYCLES - 1)) begin
                sec_cnt <= 32'd0;
                fps     <= fps_win + {15'd0, tick_axi};
                fps_win <= 16'd0;
            end else begin
                sec_cnt <= sec_cnt + 32'd1;
                if (tick_axi) fps_win <= fps_win + 16'd1;
            end

            if (clr_cnt) frame_cnt <= 32'd0;

            // priority: W1C clear < SW_IRQ < real frame event
            if (w1c_irq)   irq_status <= 1'b0;
            if (sw_irq)    irq_status <= 1'b1;
            if (tick_axi)  irq_status <= 1'b1;

            if (tick_axi) begin
                snap      <= hold;
                frame_cnt <= frame_cnt + 32'd1;
            end
        end
    end

    // ------------------------------------------------------------------
    // AXI4-Lite write channel
    // ------------------------------------------------------------------
    reg                               aw_done, w_done, bvalid_r;
    reg [C_S_AXI_ADDR_WIDTH-1:0]      awaddr_lat;
    reg [C_S_AXI_DATA_WIDTH-1:0]      wdata_lat;
    reg [(C_S_AXI_DATA_WIDTH/8)-1:0]  wstrb_lat;

    wire wr_commit = aw_done && w_done && !bvalid_r;

    assign s_axi_awready = ~aw_done;
    assign s_axi_wready  = ~w_done;
    assign s_axi_bvalid  = bvalid_r;
    assign s_axi_bresp   = 2'b00;

    always @(posedge s_axi_aclk or negedge s_axi_aresetn) begin
        if (!s_axi_aresetn) begin
            aw_done    <= 1'b0;
            w_done     <= 1'b0;
            bvalid_r   <= 1'b0;
            awaddr_lat <= {C_S_AXI_ADDR_WIDTH{1'b0}};
            wdata_lat  <= {C_S_AXI_DATA_WIDTH{1'b0}};
            wstrb_lat  <= {(C_S_AXI_DATA_WIDTH/8){1'b0}};
        end else begin
            if (s_axi_awvalid && s_axi_awready) begin
                aw_done    <= 1'b1;
                awaddr_lat <= s_axi_awaddr;
            end
            if (s_axi_wvalid && s_axi_wready) begin
                w_done    <= 1'b1;
                wdata_lat <= s_axi_wdata;
                wstrb_lat <= s_axi_wstrb;
            end
            if (wr_commit)
                bvalid_r <= 1'b1;
            if (bvalid_r && s_axi_bready) begin
                bvalid_r <= 1'b0;
                aw_done  <= 1'b0;
                w_done   <= 1'b0;
            end
        end
    end

    // register writes
    always @(posedge s_axi_aclk or negedge s_axi_aresetn) begin
        if (!s_axi_aresetn) begin
            sw_irq      <= 1'b0;
            clr_cnt     <= 1'b0;
            w1c_irq     <= 1'b0;
            irq_en      <= 1'b0;
            scratch     <= 32'd0;
        end else begin
            sw_irq  <= 1'b0;
            clr_cnt <= 1'b0;
            w1c_irq <= 1'b0;

            if (wr_commit) begin
                case (awaddr_lat[C_S_AXI_ADDR_WIDTH-1:2])
                    REG_CTRL: begin
                        if (wstrb_lat[0]) begin
                            sw_irq  <= wdata_lat[0];
                            clr_cnt <= wdata_lat[1];
                        end
                    end
                    REG_IRQ_EN: begin
                        if (wstrb_lat[0]) irq_en <= wdata_lat[0];
                    end
                    REG_IRQ_STAT: begin
                        if (wstrb_lat[0]) w1c_irq <= wdata_lat[0];
                    end
                    REG_SCRATCH: begin
                        if (wstrb_lat[0]) scratch[7:0]   <= wdata_lat[7:0];
                        if (wstrb_lat[1]) scratch[15:8]  <= wdata_lat[15:8];
                        if (wstrb_lat[2]) scratch[23:16] <= wdata_lat[23:16];
                        if (wstrb_lat[3]) scratch[31:24] <= wdata_lat[31:24];
                    end
                    default: ;
                endcase
            end
        end
    end

    // ------------------------------------------------------------------
    // AXI4-Lite read channel
    // ------------------------------------------------------------------
    reg [C_S_AXI_DATA_WIDTH-1:0] rdata_r;
    reg                          rvalid_r;
    reg [C_S_AXI_DATA_WIDTH-1:0] rd_mux;

    assign s_axi_arready = ~rvalid_r;
    assign s_axi_rvalid  = rvalid_r;
    assign s_axi_rresp   = 2'b00;
    assign s_axi_rdata   = rdata_r;

    always @(*) begin
        case (s_axi_araddr[C_S_AXI_ADDR_WIDTH-1:2])
            REG_ID:        rd_mux = ID_VALUE;
            REG_CTRL:      rd_mux = 32'd0;                       // write-only bits
            REG_IRQ_EN:    rd_mux = {31'd0, irq_en};
            REG_IRQ_STAT:  rd_mux = {31'd0, irq_status};
            REG_SCRATCH:   rd_mux = scratch;
            REG_FRAME_CNT: rd_mux = frame_cnt;
            REG_FPS:       rd_mux = {16'd0, fps};
            REG_FLAGS:     rd_mux = {13'd0, snap[49:47], snap[57:50],
                                     1'b0, snap[46:41], snap[40]};
            REG_CX:        rd_mux = {22'd0, snap[39:30]};
            REG_CY:        rd_mux = {22'd0, snap[29:20]};
            REG_AX:        rd_mux = {22'd0, snap[19:10]};
            REG_AY:        rd_mux = {22'd0, snap[9:0]};
            REG_BW:        rd_mux = {21'd0, snap[184:174]};
            REG_AREA:      rd_mux = snap[173:142];
            REG_DIST:      rd_mux = {16'd0, snap[141:126]};
            REG_DROP:      rd_mux = {16'd0, snap[125:110]};
            REG_VX:        rd_mux = {{16{snap[109]}}, snap[109:94]};
            REG_VY:        rd_mux = {{16{snap[93]}},  snap[93:78]};
            REG_PX:        rd_mux = {22'd0, snap[77:68]};
            REG_PY:        rd_mux = {22'd0, snap[67:58]};
            default:       rd_mux = 32'd0;
        endcase
    end

    always @(posedge s_axi_aclk or negedge s_axi_aresetn) begin
        if (!s_axi_aresetn) begin
            rvalid_r <= 1'b0;
            rdata_r  <= 32'd0;
        end else begin
            if (s_axi_arvalid && s_axi_arready) begin
                rvalid_r <= 1'b1;
                rdata_r  <= rd_mux;
            end else if (rvalid_r && s_axi_rready) begin
                rvalid_r <= 1'b0;
            end
        end
    end

    // ------------------------------------------------------------------
    assign irq = irq_status & irq_en;

endmodule
