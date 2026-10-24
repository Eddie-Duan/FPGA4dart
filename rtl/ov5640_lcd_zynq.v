//----------------------------------------------------------------------------------------
// File name:           ov5640_lcd_zynq
// Description:
//   PL top level for the Zynq port of the FPGA4dart vision pipeline.
//   Target: ALIENTEK ZYNQ MicroSYS small system board, XC7Z020CLG400-2.
//
//   Data path is the same as the Artix-7 build except for the frame buffer:
//     OV5640 -> ov5640_dri -> wr_fifo --> PS DDR3 (S_AXI_HP0) --> rd_fifo
//            -> armor_vision -> lcd_rgb_top -> RGB LCD
//
//   The self-built PL DDR3 controller (rtl/ddr3_top.v + rtl/ddr3_rw.v + MIG) is
//   replaced by rtl/ddr3_fifo_ctrl.v + rtl/axi_frame_buf.v. ddr3_fifo_ctrl keeps
//   its 128-bit stream interface, so the vision chain is untouched; only the
//   memory behind it moved from a PL MIG to the PS DDR3 controller.
//
//   Clocks come from the PS block design:
//     ui_clk      = FCLK_CLK0, 100 MHz -> AXI + frame buffer
//     lcd_sys_clk = FCLK_CLK1,  50 MHz -> LCD and vision domain (the rate the
//                                         Artix-7 build used on clk_out2)
//   The 200 MHz clk_wiz output existed only to feed the MIG, so clk_wiz_0 is
//   no longer instantiated here.
//
//   Board notes:
//     - the 18-pin CAMERA header P1 is wired in parallel with the RGB LCD
//       connector on 14 nets, so P1 must stay empty while the LCD is connected.
//       The 2x9 camera plug instead goes straight onto the lower 2x25 header:
//       9 columns starting at the "3.3V"/"GND" column (the "CMOS2" group in the
//       board IO table). Pin list in prj/zynq_challenger.xdc, wiring table in
//       ZYNQ_TEST_PLAN.md section 0.1
//     - the board has a single PL key, used here as sys reset; armor_vision's
//       key bus is tied idle and thresholds are changed over UART instead
//     - the board has no 7-segment display, so seg_sel/seg_led stay internal
//     - AXI is wired straight to S_AXI_HP0 (AXI3, 64-bit, 6-bit IDs). Each
//       128-bit FIFO word is transferred as two 64-bit beats.
//----------------------------------------------------------------------------------------

`timescale 1ns / 1ps

module ov5640_lcd_zynq (
    (* X_INTERFACE_INFO = "xilinx.com:signal:clock:1.0 UI_CLK CLK",
       X_INTERFACE_PARAMETER = "XIL_INTERFACENAME UI_CLK, ASSOCIATED_BUSIF M_AXI, ASSOCIATED_RESET rst_n, FREQ_HZ 100000000" *)
    input          ui_clk        , // FCLK_CLK0, 100 MHz
    (* X_INTERFACE_INFO = "xilinx.com:signal:clock:1.0 LCD_SYS_CLK CLK",
       X_INTERFACE_PARAMETER = "XIL_INTERFACENAME LCD_SYS_CLK, FREQ_HZ 50000000" *)
    input          lcd_sys_clk   , // FCLK_CLK1,  50 MHz
    (* X_INTERFACE_INFO = "xilinx.com:signal:reset:1.0 rst_n RST",
       X_INTERFACE_PARAMETER = "XIL_INTERFACENAME rst_n, POLARITY ACTIVE_LOW" *)
    input          rst_n         , // PS reset, active low

    // camera DVP on header J7
    input          cam_pclk      ,
    input          cam_vsync     ,
    input          cam_href      ,
    input  [7:0]   cam_data      ,
    output         cam_rst_n     ,
    output         cam_pwdn      ,
    output         cam_scl       ,
    inout          cam_sda       ,

    // onboard RGB LCD header
    output         lcd_hs        ,
    output         lcd_vs        ,
    output         lcd_de        ,
    output         lcd_bl        ,
    output         lcd_rst       ,
    output         lcd_pclk      ,
    inout  [23:0]  lcd_rgb       ,

    // onboard PL LED and external USB-TTL UART
    output         led           ,
    input          uart_rxd      ,
    output         uart_txd      ,

    // AXI3 master -> PS S_AXI_HP0
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI AWADDR",
       X_INTERFACE_PARAMETER = "XIL_INTERFACENAME M_AXI, PROTOCOL AXI3, DATA_WIDTH 64, ADDR_WIDTH 32, ID_WIDTH 6, FREQ_HZ 100000000, READ_WRITE_MODE READ_WRITE, MAX_BURST_LENGTH 16, HAS_BURST 1, HAS_CACHE 1, HAS_LOCK 1, HAS_PROT 1, HAS_QOS 0, SUPPORTS_NARROW_BURST 0" *)
    output [31:0]  m_axi_awaddr  ,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI AWID" *)
    output [5:0]   m_axi_awid    ,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI AWLEN" *)
    output [3:0]   m_axi_awlen   ,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI AWSIZE" *)
    output [2:0]   m_axi_awsize  ,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI AWBURST" *)
    output [1:0]   m_axi_awburst ,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI AWLOCK" *)
    output [1:0]   m_axi_awlock  ,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI AWCACHE" *)
    output [3:0]   m_axi_awcache ,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI AWPROT" *)
    output [2:0]   m_axi_awprot  ,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI AWVALID" *)
    output         m_axi_awvalid ,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI AWREADY" *)
    input          m_axi_awready ,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI WID" *)
    output [5:0]   m_axi_wid     ,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI WDATA" *)
    output [63:0]  m_axi_wdata   ,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI WSTRB" *)
    output [7:0]   m_axi_wstrb   ,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI WLAST" *)
    output         m_axi_wlast   ,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI WVALID" *)
    output         m_axi_wvalid  ,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI WREADY" *)
    input          m_axi_wready  ,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI BID" *)
    input  [5:0]   m_axi_bid     ,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI BRESP" *)
    input  [1:0]   m_axi_bresp   ,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI BVALID" *)
    input          m_axi_bvalid  ,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI BREADY" *)
    output         m_axi_bready  ,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI ARADDR" *)
    output [31:0]  m_axi_araddr  ,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI ARID" *)
    output [5:0]   m_axi_arid    ,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI ARLEN" *)
    output [3:0]   m_axi_arlen   ,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI ARSIZE" *)
    output [2:0]   m_axi_arsize  ,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI ARBURST" *)
    output [1:0]   m_axi_arburst ,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI ARLOCK" *)
    output [1:0]   m_axi_arlock  ,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI ARCACHE" *)
    output [3:0]   m_axi_arcache ,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI ARPROT" *)
    output [2:0]   m_axi_arprot  ,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI ARVALID" *)
    output         m_axi_arvalid ,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI ARREADY" *)
    input          m_axi_arready ,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI RDATA" *)
    input  [63:0]  m_axi_rdata   ,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI RID" *)
    input  [5:0]   m_axi_rid     ,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI RRESP" *)
    input  [1:0]   m_axi_rresp   ,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI RVALID" *)
    input          m_axi_rvalid  ,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI RLAST" *)
    input          m_axi_rlast   ,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI RREADY" *)
    output         m_axi_rready
);

//--------------------------------------------------------------------------
// internal signals
//--------------------------------------------------------------------------
wire         startup_delay_done;    // delay only; DDR must be initialized by PS boot
wire         sys_init_done;
wire         lcd_clk;               // 25 MHz pixel clock out of lcd_rgb_top
wire         rd_vsync;              // LCD frame start
wire         rdata_req;
wire  [15:0] rddata;
wire  [15:0] lcd_data;

wire  [15:0] wrdata;                // camera pixels, RGB565
wire         cmos_frame_vsync;
wire         cmos_frame_valid;
wire         cam_init_done;

wire  [12:0] h_disp;
wire  [12:0] v_disp;
wire  [12:0] total_h_pixel;
wire  [12:0] total_v_pixel;
wire  [12:0] y_addr_st;
wire  [12:0] y_addr_end;
wire  [27:0] ddr3_addr_max;
wire  [15:0] lcd_id;

wire  [127:0] wfifo_dout;
wire  [9:0]   wfifo_rcount;
wire          wfifo_rden;
wire  [127:0] rfifo_din;
wire          rfifo_wren;
wire  [9:0]   rfifo_wcount;

wire  [3:0]  vision_led;
wire  [5:0]  seg_sel;
wire  [7:0]  seg_led;
wire         vision_bond_valid;
wire         axi_error;

assign sys_init_done = startup_delay_done;

// The only onboard PL LED shows target detection or an AXI response error.
assign led = vision_led[3] | axi_error;

//--------------------------------------------------------------------------
// camera configuration and DVP capture
//--------------------------------------------------------------------------
picture_size u_picture_size (
    .rst_n              (rst_n         ),
    .clk                (lcd_sys_clk   ),
    .lcd_id             (lcd_id        ),
    .cmos_h_pixel       (h_disp        ),
    .cmos_v_pixel       (v_disp        ),
    .total_h_pixel      (total_h_pixel ),
    .total_v_pixel      (total_v_pixel ),
    .y_addr_st          (y_addr_st     ),
    .y_addr_end         (y_addr_end    ),
    .ddr3_addr_max      (ddr3_addr_max )
    );

ov5640_dri u_ov5640_dri (
    .clk               (lcd_sys_clk       ),
    .rst_n             (rst_n             ),
    .cam_pclk          (cam_pclk          ),
    .cam_vsync         (cam_vsync         ),
    .cam_href          (cam_href          ),
    .cam_data          (cam_data          ),
    .cam_rst_n         (cam_rst_n         ),
    .cam_pwdn          (cam_pwdn          ),
    .cam_scl           (cam_scl           ),
    .cam_sda           (cam_sda           ),
    .capture_start     (startup_delay_done && cam_init_done),
    .cam_init_done     (cam_init_done     ),
    .cmos_h_pixel      (h_disp            ),
    .cmos_v_pixel      (v_disp            ),
    .total_h_pixel     (total_h_pixel     ),
    .total_v_pixel     (total_v_pixel     ),
    .y_addr_st         (y_addr_st         ),
    .y_addr_end        (y_addr_end        ),
    .cmos_frame_vsync  (cmos_frame_vsync  ),
    .cmos_frame_href   (                  ),
    .cmos_frame_valid  (cmos_frame_valid  ),
    .cmos_frame_data   (wrdata            )
    );

//--------------------------------------------------------------------------
// frame buffer: 128-bit stream <-> PS DDR3 over AXI
//--------------------------------------------------------------------------
ddr3_fifo_ctrl u_ddr3_fifo_ctrl (
    .rst_n          (rst_n             ),
    .wr_clk         (cam_pclk          ),
    .rd_clk         (lcd_clk           ),
    .ui_clk         (ui_clk            ),
    .wr_en          (cmos_frame_valid  ),
    .wrdata         (wrdata            ),
    .rfifo_din      (rfifo_din         ),
    .rdata_req      (rdata_req         ),
    .rfifo_wren     (rfifo_wren        ),
    .wfifo_rden     (wfifo_rden        ),
    .rd_load        (rd_vsync          ),
    .wr_load        (cmos_frame_vsync  ),
    .wfifo_dout     (wfifo_dout        ),
    .rfifo_wcount   (rfifo_wcount      ),
    .wfifo_rcount   (wfifo_rcount      ),
    .rddata         (rddata            )
    );

axi_frame_buf u_axi_frame_buf (
    .ui_clk               (ui_clk             ),
    .rst_n                (rst_n              ),
    .startup_delay_done   (startup_delay_done),
    .wfifo_dout           (wfifo_dout         ),
    .wfifo_rcount         (wfifo_rcount       ),
    .wfifo_rden           (wfifo_rden         ),
    .rfifo_din            (rfifo_din          ),
    .rfifo_wren           (rfifo_wren         ),
    .rfifo_wcount         (rfifo_wcount       ),
    .wr_load              (cmos_frame_vsync   ),
    .rd_load              (rd_vsync           ),
    .ddr3_read_valid      (1'b1               ),
    .m_axi_awaddr         (m_axi_awaddr       ),
    .m_axi_awid           (m_axi_awid         ),
    .m_axi_awlen          (m_axi_awlen        ),
    .m_axi_awsize         (m_axi_awsize       ),
    .m_axi_awburst        (m_axi_awburst      ),
    .m_axi_awlock         (m_axi_awlock       ),
    .m_axi_awcache        (m_axi_awcache      ),
    .m_axi_awprot         (m_axi_awprot       ),
    .m_axi_awvalid        (m_axi_awvalid      ),
    .m_axi_awready        (m_axi_awready      ),
    .m_axi_wid            (m_axi_wid          ),
    .m_axi_wdata          (m_axi_wdata        ),
    .m_axi_wstrb          (m_axi_wstrb        ),
    .m_axi_wlast          (m_axi_wlast        ),
    .m_axi_wvalid         (m_axi_wvalid       ),
    .m_axi_wready         (m_axi_wready       ),
    .m_axi_bid            (m_axi_bid          ),
    .m_axi_bresp          (m_axi_bresp        ),
    .m_axi_bvalid         (m_axi_bvalid       ),
    .m_axi_bready         (m_axi_bready       ),
    .m_axi_araddr         (m_axi_araddr       ),
    .m_axi_arid           (m_axi_arid         ),
    .m_axi_arlen          (m_axi_arlen        ),
    .m_axi_arsize         (m_axi_arsize       ),
    .m_axi_arburst        (m_axi_arburst      ),
    .m_axi_arlock         (m_axi_arlock       ),
    .m_axi_arcache        (m_axi_arcache      ),
    .m_axi_arprot         (m_axi_arprot       ),
    .m_axi_arvalid        (m_axi_arvalid      ),
    .m_axi_arready        (m_axi_arready      ),
    .m_axi_rdata          (m_axi_rdata        ),
    .m_axi_rid            (m_axi_rid          ),
    .m_axi_rresp          (m_axi_rresp        ),
    .m_axi_rvalid         (m_axi_rvalid       ),
    .m_axi_rlast          (m_axi_rlast        ),
    .m_axi_rready         (m_axi_rready       ),
    .axi_error            (axi_error          )
    );

//--------------------------------------------------------------------------
// LCD timing
//--------------------------------------------------------------------------
lcd_rgb_top u_lcd_rgb_top (
    .sys_clk        (lcd_sys_clk   ),
    .sys_rst_n      (rst_n         ),
    .sys_init_done  (sys_init_done ),
    .lcd_id         (lcd_id        ),
    .lcd_hs         (lcd_hs        ),
    .lcd_vs         (lcd_vs        ),
    .lcd_de         (lcd_de        ),
    .lcd_rgb        (lcd_rgb       ),
    .lcd_bl         (lcd_bl        ),
    .lcd_rst        (lcd_rst       ),
    .lcd_pclk       (lcd_pclk      ),
    .lcd_clk        (lcd_clk       ),
    .out_vsync      (rd_vsync      ),
    .h_disp         (              ),
    .v_disp         (              ),
    .pixel_xpos     (              ),
    .pixel_ypos     (              ),
    .data_in        (lcd_data      ),
    .data_req       (rdata_req     )
    );

//--------------------------------------------------------------------------
// vision pipeline
//--------------------------------------------------------------------------
// The board has a single PL key and it is used as the system reset, so the
// keypad bus stays idle and thresholds are written over UART instead.
armor_vision u_armor_vision (
    .clk        (lcd_clk         ),
    .rst_n      (rst_n           ),
    .vsync      (rd_vsync        ),
    .de         (rdata_req       ),
    .data_in    (rddata          ),
    .key        (4'b1111         ),
    .data_out   (lcd_data        ),
    .led        (vision_led      ),
    .seg_sel    (seg_sel         ),
    .seg_led    (seg_led         ),
    .bond_valid (vision_bond_valid),
    .center_x   (                ),
    .center_y   (                ),
    .aim_x      (                ),
    .aim_y      (                ),
    .uart_rxd   (uart_rxd        ),
    .uart_txd   (uart_txd        )
    );

endmodule
