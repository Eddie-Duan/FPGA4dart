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
//     - the camera is wired to header J7 (bank35); the 18-pin CAMERA header P1
//       shares 12 bank34 nets with the RGB LCD header and cannot be used at the
//       same time as the LCD (see ZYNQ_TEST_PLAN.md section 0.1)
//     - the board has a single PL key, used here as sys reset; armor_vision's
//       key bus is tied idle and thresholds are changed over UART instead
//     - the board has no 7-segment display, so seg_sel/seg_led stay internal
//     - AXI is wired straight to S_AXI_HP0 (AXI3, 128-bit). AWLEN/ARLEN only use
//       the low 4 bits, which is enough for the 16-beat bursts axi_frame_buf issues.
//----------------------------------------------------------------------------------------

`timescale 1ns / 1ps

module ov5640_lcd_zynq (
    input          ui_clk        , // FCLK_CLK0, 100 MHz
    input          lcd_sys_clk   , // FCLK_CLK1, 50 MHz
    input          rst_n         , // PS peripheral reset, active low

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

    // AXI4 master -> PS S_AXI_HP0
    output [31:0]  m_axi_awaddr  ,
    output [7:0]   m_axi_awlen   ,
    output [2:0]   m_axi_awsize  ,
    output [1:0]   m_axi_awburst ,
    output         m_axi_awlock  ,
    output [3:0]   m_axi_awcache ,
    output [2:0]   m_axi_awprot  ,
    output [3:0]   m_axi_awqos   ,
    output         m_axi_awvalid ,
    input          m_axi_awready ,
    output [127:0] m_axi_wdata   ,
    output [15:0]  m_axi_wstrb   ,
    output         m_axi_wlast   ,
    output         m_axi_wvalid  ,
    input          m_axi_wready  ,
    input  [1:0]   m_axi_bresp   ,
    input          m_axi_bvalid  ,
    output         m_axi_bready  ,
    output [31:0]  m_axi_araddr  ,
    output [7:0]   m_axi_arlen   ,
    output [2:0]   m_axi_arsize  ,
    output [1:0]   m_axi_arburst ,
    output         m_axi_arlock  ,
    output [3:0]   m_axi_arcache ,
    output [2:0]   m_axi_arprot  ,
    output [3:0]   m_axi_arqos   ,
    output         m_axi_arvalid ,
    input          m_axi_arready ,
    input  [127:0] m_axi_rdata   ,
    input  [1:0]   m_axi_rresp   ,
    input          m_axi_rvalid  ,
    input          m_axi_rlast   ,
    output         m_axi_rready
);

//--------------------------------------------------------------------------
// internal signals
//--------------------------------------------------------------------------
wire         init_calib_complete;   // DDR usable, from axi_frame_buf
wire         sys_init_done;
wire         lcd_clk;               // 25 MHz pixel clock out of lcd_rgb_top
wire         rd_vsync;              // LCD frame start
wire         rdata_req;
wire  [15:0] rddata;
wire  [15:0] lcd_data;

wire  [15:0] wrdata;                // camera pixels, RGB565
wire         cmos_frame_vsync;
wire         cmos_frame_valid;

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

assign sys_init_done = init_calib_complete;

// the only onboard PL LED shows the vision LED[3] (target detected)
assign led = vision_led[3];

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
    .capture_start     (init_calib_complete),
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
    .init_calib_complete  (init_calib_complete),
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
    .m_axi_awlen          (m_axi_awlen        ),
    .m_axi_awsize         (m_axi_awsize       ),
    .m_axi_awburst        (m_axi_awburst      ),
    .m_axi_awlock         (m_axi_awlock       ),
    .m_axi_awcache        (m_axi_awcache      ),
    .m_axi_awprot         (m_axi_awprot       ),
    .m_axi_awqos          (m_axi_awqos        ),
    .m_axi_awvalid        (m_axi_awvalid      ),
    .m_axi_awready        (m_axi_awready      ),
    .m_axi_wdata          (m_axi_wdata        ),
    .m_axi_wstrb          (m_axi_wstrb        ),
    .m_axi_wlast          (m_axi_wlast        ),
    .m_axi_wvalid         (m_axi_wvalid       ),
    .m_axi_wready         (m_axi_wready       ),
    .m_axi_bresp          (m_axi_bresp        ),
    .m_axi_bvalid         (m_axi_bvalid       ),
    .m_axi_bready         (m_axi_bready       ),
    .m_axi_araddr         (m_axi_araddr       ),
    .m_axi_arlen          (m_axi_arlen        ),
    .m_axi_arsize         (m_axi_arsize       ),
    .m_axi_arburst        (m_axi_arburst      ),
    .m_axi_arlock         (m_axi_arlock       ),
    .m_axi_arcache        (m_axi_arcache      ),
    .m_axi_arprot         (m_axi_arprot       ),
    .m_axi_arqos          (m_axi_arqos        ),
    .m_axi_arvalid        (m_axi_arvalid      ),
    .m_axi_arready        (m_axi_arready      ),
    .m_axi_rdata          (m_axi_rdata        ),
    .m_axi_rresp          (m_axi_rresp        ),
    .m_axi_rvalid         (m_axi_rvalid       ),
    .m_axi_rlast          (m_axi_rlast        ),
    .m_axi_rready         (m_axi_rready       )
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
