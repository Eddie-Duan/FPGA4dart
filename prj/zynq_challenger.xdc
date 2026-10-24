# 正点原子 ZYNQ MicroSYS（XC7Z020CLG400-2）PL 引脚约束
# 引脚依据：系统板原理图.pdf（STUDYBOARD.08 A，第 11 页 RGBLCD/CAMERA 图纸）
#           与《ZYNQ小系统开发板 IO引脚分配总表.xlsx》互相核对，二者一致。
#
# 【重要】板上 18 脚 CAMERA 座 P1（丝印 3.3V/VSYNC/HREF/RST/D1..D7/XCLK/PCLK/PWDN）
#   与 42 脚 RGB LCD 座（AWM 排线那个）并接了 14 根网络：
#     P1 信号      P1 网络       共用它的 LCD 信号
#     VSYNC        B34_L2_N      LCD_R5
#     HREF         B34_L2_P      LCD_R7
#     RESET        B34_L6_P      LCD_G2
#     PCLK         B34_L4_P      LCD_R0
#     SCL          B34_L1_N      LCD_R1
#     SDA          B34_L1_P      LCD_R3
#     D0           B34_L6_N      LCD_G0
#     D1           B34_L3_P      LCD_R4
#     D2           B34_L3_N      LCD_R6
#     D3           B34_L11_N     LCD_G7
#     D4           B34_L11_P     LCD_G5
#     D5           B34_L5_N      LCD_G3
#     D6           B34_L5_P      LCD_G1
#     D7           B34_L4_N      LCD_R2
#   => LCD 插着时 P1 必须空着。
#
#   好消息：不用一根根飞线。P1 那个 2x9 母座可以直接整排插到下方 2x25 排针上：
#   从丝印 "3.3V" 那一列开始，往右正好 9 列、每列上下各一个脚，且第 1 列上排是
#   3.3V、下排是 GND，和相机插头的 1/2 脚完全对上。这 16 个信号脚正好就是 IO
#   分配表里 "CMOS2" 那一组。插法：
#
#     P1 位置       排针列（上排/下排）      FPGA
#     1 3.3V        3.3V / GND              --
#     2 GND
#     3 VSYNC       H15  / H16              cam_vsync / cam_scl
#     4 SCL
#     5 HREF        G15  / H17              cam_href  / cam_sda
#     6 SDA
#     7 RST         N15  / E17              cam_rst_n / cam_data[0]
#     8 D0
#     9 D1          N16  / D18              cam_data[1] / cam_data[2]
#    10 D2
#    11 D3          M14  / G17              cam_data[3] / cam_data[4]
#    12 D4
#    13 D5          M15  / G18              cam_data[5] / cam_data[6]
#    14 D6
#    15 D7          L14  / K17              cam_data[7] / cam_pclk
#    16 PCLK
#    17 XCLK        L15  / K18              (空) / cam_pwdn
#    18 PWDN
#
#   注意 3.3V 那一列左边紧挨着的是 5V，别插错一格。
#   FCLK_CLK0/1 与 FCLK_RESET0_N 是 PS->PL 内部连接，不占 I/O。

# ---------------- PL LED ----------------
set_property -dict {PACKAGE_PIN G14 IOSTANDARD LVCMOS33} [get_ports led]

# ---------------- 24bit RGB LCD（AWM 排线，42 脚座） ----------------
# lcd_rgb[7:0] = B0..B7，[15:8] = G0..G7，[23:16] = R0..R7
set_property -dict {PACKAGE_PIN T16 IOSTANDARD LVCMOS33} [get_ports {lcd_rgb[0]}]
set_property -dict {PACKAGE_PIN R16 IOSTANDARD LVCMOS33} [get_ports {lcd_rgb[1]}]
set_property -dict {PACKAGE_PIN U17 IOSTANDARD LVCMOS33} [get_ports {lcd_rgb[2]}]
set_property -dict {PACKAGE_PIN R17 IOSTANDARD LVCMOS33} [get_ports {lcd_rgb[3]}]
set_property -dict {PACKAGE_PIN T17 IOSTANDARD LVCMOS33} [get_ports {lcd_rgb[4]}]
set_property -dict {PACKAGE_PIN R19 IOSTANDARD LVCMOS33} [get_ports {lcd_rgb[5]}]
set_property -dict {PACKAGE_PIN R18 IOSTANDARD LVCMOS33} [get_ports {lcd_rgb[6]}]
set_property -dict {PACKAGE_PIN P18 IOSTANDARD LVCMOS33} [get_ports {lcd_rgb[7]}]
set_property -dict {PACKAGE_PIN R14 IOSTANDARD LVCMOS33} [get_ports {lcd_rgb[8]}]
set_property -dict {PACKAGE_PIN T14 IOSTANDARD LVCMOS33} [get_ports {lcd_rgb[9]}]
set_property -dict {PACKAGE_PIN P14 IOSTANDARD LVCMOS33} [get_ports {lcd_rgb[10]}]
set_property -dict {PACKAGE_PIN T15 IOSTANDARD LVCMOS33} [get_ports {lcd_rgb[11]}]
set_property -dict {PACKAGE_PIN P15 IOSTANDARD LVCMOS33} [get_ports {lcd_rgb[12]}]
set_property -dict {PACKAGE_PIN U14 IOSTANDARD LVCMOS33} [get_ports {lcd_rgb[13]}]
set_property -dict {PACKAGE_PIN P16 IOSTANDARD LVCMOS33} [get_ports {lcd_rgb[14]}]
set_property -dict {PACKAGE_PIN U15 IOSTANDARD LVCMOS33} [get_ports {lcd_rgb[15]}]
set_property -dict {PACKAGE_PIN V12 IOSTANDARD LVCMOS33} [get_ports {lcd_rgb[16]}]
set_property -dict {PACKAGE_PIN T10 IOSTANDARD LVCMOS33} [get_ports {lcd_rgb[17]}]
set_property -dict {PACKAGE_PIN W13 IOSTANDARD LVCMOS33} [get_ports {lcd_rgb[18]}]
set_property -dict {PACKAGE_PIN T11 IOSTANDARD LVCMOS33} [get_ports {lcd_rgb[19]}]
set_property -dict {PACKAGE_PIN U13 IOSTANDARD LVCMOS33} [get_ports {lcd_rgb[20]}]
set_property -dict {PACKAGE_PIN U12 IOSTANDARD LVCMOS33} [get_ports {lcd_rgb[21]}]
set_property -dict {PACKAGE_PIN V13 IOSTANDARD LVCMOS33} [get_ports {lcd_rgb[22]}]
set_property -dict {PACKAGE_PIN T12 IOSTANDARD LVCMOS33} [get_ports {lcd_rgb[23]}]

set_property -dict {PACKAGE_PIN W18 IOSTANDARD LVCMOS33} [get_ports lcd_hs]
set_property -dict {PACKAGE_PIN P19 IOSTANDARD LVCMOS33} [get_ports lcd_vs]
set_property -dict {PACKAGE_PIN W19 IOSTANDARD LVCMOS33} [get_ports lcd_de]
set_property -dict {PACKAGE_PIN N18 IOSTANDARD LVCMOS33} [get_ports lcd_bl]
set_property -dict {PACKAGE_PIN N17 IOSTANDARD LVCMOS33} [get_ports lcd_pclk]
set_property -dict {PACKAGE_PIN T19 IOSTANDARD LVCMOS33} [get_ports lcd_rst]

# ---------------- OV5640 DVP（2x9 母座整排插在下方 2x25 排针，见文件头） ----------------
create_clock -period 20.000 -name cam_pclk [get_ports cam_pclk]
set_property -dict {PACKAGE_PIN K17 IOSTANDARD LVCMOS33} [get_ports cam_pclk]
set_property -dict {PACKAGE_PIN H15 IOSTANDARD LVCMOS33} [get_ports cam_vsync]
set_property -dict {PACKAGE_PIN G15 IOSTANDARD LVCMOS33} [get_ports cam_href]
set_property -dict {PACKAGE_PIN E17 IOSTANDARD LVCMOS33} [get_ports {cam_data[0]}]
set_property -dict {PACKAGE_PIN N16 IOSTANDARD LVCMOS33} [get_ports {cam_data[1]}]
set_property -dict {PACKAGE_PIN D18 IOSTANDARD LVCMOS33} [get_ports {cam_data[2]}]
set_property -dict {PACKAGE_PIN M14 IOSTANDARD LVCMOS33} [get_ports {cam_data[3]}]
set_property -dict {PACKAGE_PIN G17 IOSTANDARD LVCMOS33} [get_ports {cam_data[4]}]
set_property -dict {PACKAGE_PIN M15 IOSTANDARD LVCMOS33} [get_ports {cam_data[5]}]
set_property -dict {PACKAGE_PIN G18 IOSTANDARD LVCMOS33} [get_ports {cam_data[6]}]
set_property -dict {PACKAGE_PIN L14 IOSTANDARD LVCMOS33} [get_ports {cam_data[7]}]
set_property -dict {PACKAGE_PIN N15 IOSTANDARD LVCMOS33} [get_ports cam_rst_n]
set_property -dict {PACKAGE_PIN K18 IOSTANDARD LVCMOS33} [get_ports cam_pwdn]
set_property -dict {PACKAGE_PIN H16 IOSTANDARD LVCMOS33} [get_ports cam_scl]
set_property -dict {PACKAGE_PIN H17 IOSTANDARD LVCMOS33} [get_ports cam_sda]
set_property PULLUP true [get_ports cam_scl]
set_property PULLUP true [get_ports cam_sda]

# ---------------- 外部 USB-TTL 串口（结果帧上报 / 参数写入） ----------------
# 板载 USB-UART 接的是 PS 的 MIO14/15，PL 用不了，这里仍走排针外接。
set_property -dict {PACKAGE_PIN F19 IOSTANDARD LVCMOS33} [get_ports uart_rxd]
set_property -dict {PACKAGE_PIN F20 IOSTANDARD LVCMOS33} [get_ports uart_txd]

# DDR 属于 Zynq PS，不能当 PL I/O 约束。
