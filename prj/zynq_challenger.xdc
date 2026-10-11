# 挑战者底板, XC7Z020CLG400-2.
# Constraints for the standalone Zynq PL design; do not add to ov5640_lcd.xpr.
# LCD pins follow G:\ZYNQ7020\27_ov7725_hdmi\...\LCD.xdc. Camera is wired
# to J7 (bank35), using the net-to-package-pin mapping in 系统板原理图.pdf.
#
# IMPORTANT: the 18-pin CAMERA header P1 shares 12 bank34 nets with the RGB LCD
# header (LCD_R0-R7, LCD_G0/G2/G5/G7 are wired in parallel with CMOS_D0-D6,
# VSYNC, HREF, SCL, SDA, RESET). The two headers cannot be populated at once.
# The camera is therefore wired to the J7 header (bank35), which is independent.

# FCLK_CLK0/1 and FCLK_RESET0_N are internal PS-to-PL connections, not I/O pins.
# The board PL LED net is B35_IO0 at G14.
set_property -dict {PACKAGE_PIN G14 IOSTANDARD LVCMOS33} [get_ports led]

# 24-bit RGB LCD interface
set_property -dict {PACKAGE_PIN W18 IOSTANDARD LVCMOS33} [get_ports {lcd_rgb[0]}]
set_property -dict {PACKAGE_PIN W19 IOSTANDARD LVCMOS33} [get_ports {lcd_rgb[1]}]
set_property -dict {PACKAGE_PIN R16 IOSTANDARD LVCMOS33} [get_ports {lcd_rgb[2]}]
set_property -dict {PACKAGE_PIN R17 IOSTANDARD LVCMOS33} [get_ports {lcd_rgb[3]}]
set_property -dict {PACKAGE_PIN W20 IOSTANDARD LVCMOS33} [get_ports {lcd_rgb[4]}]
set_property -dict {PACKAGE_PIN V20 IOSTANDARD LVCMOS33} [get_ports {lcd_rgb[5]}]
set_property -dict {PACKAGE_PIN P18 IOSTANDARD LVCMOS33} [get_ports {lcd_rgb[6]}]
set_property -dict {PACKAGE_PIN N17 IOSTANDARD LVCMOS33} [get_ports {lcd_rgb[7]}]
set_property -dict {PACKAGE_PIN V17 IOSTANDARD LVCMOS33} [get_ports {lcd_rgb[8]}]
set_property -dict {PACKAGE_PIN V18 IOSTANDARD LVCMOS33} [get_ports {lcd_rgb[9]}]
set_property -dict {PACKAGE_PIN T17 IOSTANDARD LVCMOS33} [get_ports {lcd_rgb[10]}]
set_property -dict {PACKAGE_PIN R18 IOSTANDARD LVCMOS33} [get_ports {lcd_rgb[11]}]
set_property -dict {PACKAGE_PIN Y18 IOSTANDARD LVCMOS33} [get_ports {lcd_rgb[12]}]
set_property -dict {PACKAGE_PIN Y19 IOSTANDARD LVCMOS33} [get_ports {lcd_rgb[13]}]
set_property -dict {PACKAGE_PIN P15 IOSTANDARD LVCMOS33} [get_ports {lcd_rgb[14]}]
set_property -dict {PACKAGE_PIN P16 IOSTANDARD LVCMOS33} [get_ports {lcd_rgb[15]}]
set_property -dict {PACKAGE_PIN V16 IOSTANDARD LVCMOS33} [get_ports {lcd_rgb[16]}]
set_property -dict {PACKAGE_PIN W16 IOSTANDARD LVCMOS33} [get_ports {lcd_rgb[17]}]
set_property -dict {PACKAGE_PIN T14 IOSTANDARD LVCMOS33} [get_ports {lcd_rgb[18]}]
set_property -dict {PACKAGE_PIN T15 IOSTANDARD LVCMOS33} [get_ports {lcd_rgb[19]}]
set_property -dict {PACKAGE_PIN Y17 IOSTANDARD LVCMOS33} [get_ports {lcd_rgb[20]}]
set_property -dict {PACKAGE_PIN Y16 IOSTANDARD LVCMOS33} [get_ports {lcd_rgb[21]}]
set_property -dict {PACKAGE_PIN T16 IOSTANDARD LVCMOS33} [get_ports {lcd_rgb[22]}]
set_property -dict {PACKAGE_PIN U17 IOSTANDARD LVCMOS33} [get_ports {lcd_rgb[23]}]

set_property -dict {PACKAGE_PIN N18 IOSTANDARD LVCMOS33} [get_ports lcd_hs]
set_property -dict {PACKAGE_PIN T20 IOSTANDARD LVCMOS33} [get_ports lcd_vs]
set_property -dict {PACKAGE_PIN U20 IOSTANDARD LVCMOS33} [get_ports lcd_de]
set_property -dict {PACKAGE_PIN M20 IOSTANDARD LVCMOS33} [get_ports lcd_bl]
set_property -dict {PACKAGE_PIN P19 IOSTANDARD LVCMOS33} [get_ports lcd_pclk]
set_property -dict {PACKAGE_PIN L17 IOSTANDARD LVCMOS33} [get_ports lcd_rst]

# Camera DVP on header J7 (bank35), jumper wires to the header pins.
# J7 pin numbers are silkscreen numbers; cam_pclk uses the bank35 SRCC pin.
create_clock -period 40.000 -name cam_pclk [get_ports cam_pclk]
# J7-31, B35_L11_P (SRCC)
set_property -dict {PACKAGE_PIN L16 IOSTANDARD LVCMOS33} [get_ports cam_pclk]
# J7-39, B35_L24_P
set_property -dict {PACKAGE_PIN K16 IOSTANDARD LVCMOS33} [get_ports cam_vsync]
# J7-41, B35_L24_N
set_property -dict {PACKAGE_PIN J16 IOSTANDARD LVCMOS33} [get_ports cam_href]
# J7-32, B35_L20_P
set_property -dict {PACKAGE_PIN K14 IOSTANDARD LVCMOS33 IOB TRUE} [get_ports {cam_data[0]}]
# J7-34, B35_L20_N
set_property -dict {PACKAGE_PIN J14 IOSTANDARD LVCMOS33 IOB TRUE} [get_ports {cam_data[1]}]
# J7-35, B35_L8_P
set_property -dict {PACKAGE_PIN M17 IOSTANDARD LVCMOS33 IOB TRUE} [get_ports {cam_data[2]}]
# J7-37, B35_L8_N
set_property -dict {PACKAGE_PIN M18 IOSTANDARD LVCMOS33 IOB TRUE} [get_ports {cam_data[3]}]
# J7-15, B35_L19_P
set_property -dict {PACKAGE_PIN H15 IOSTANDARD LVCMOS33 IOB TRUE} [get_ports {cam_data[4]}]
# J7-17, B35_L19_N
set_property -dict {PACKAGE_PIN G15 IOSTANDARD LVCMOS33 IOB TRUE} [get_ports {cam_data[5]}]
# J7-16, B35_L13_P
set_property -dict {PACKAGE_PIN H16 IOSTANDARD LVCMOS33 IOB TRUE} [get_ports {cam_data[6]}]
# J7-18, B35_L13_N
set_property -dict {PACKAGE_PIN H17 IOSTANDARD LVCMOS33 IOB TRUE} [get_ports {cam_data[7]}]
# J7-19, B35_L21_P
set_property -dict {PACKAGE_PIN N15 IOSTANDARD LVCMOS33} [get_ports cam_scl]
# J7-21, B35_L21_N
set_property -dict {PACKAGE_PIN N16 IOSTANDARD LVCMOS33} [get_ports cam_sda]
set_property PULLUP true [get_ports cam_scl]
set_property PULLUP true [get_ports cam_sda]
# J7-23, B35_L23_P
set_property -dict {PACKAGE_PIN M14 IOSTANDARD LVCMOS33} [get_ports cam_rst_n]
# J7-25, B35_L23_N
set_property -dict {PACKAGE_PIN M15 IOSTANDARD LVCMOS33} [get_ports cam_pwdn]

# External USB-TTL UART on the remaining J7 pins (result frame / parameter writes).
# J7-47, B35_L15_P
set_property -dict {PACKAGE_PIN F19 IOSTANDARD LVCMOS33} [get_ports uart_rxd]
# J7-49, B35_L15_N
set_property -dict {PACKAGE_PIN F20 IOSTANDARD LVCMOS33} [get_ports uart_txd]

# DDR belongs to the Zynq PS and must not be constrained as PL I/O.
