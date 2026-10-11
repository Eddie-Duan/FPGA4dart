#开发板IO约束文件

#----------------------系统时钟---------------------------
set_property -dict {PACKAGE_PIN U18 IOSTANDARD LVCMOS33} [get_ports sys_clk]

#----------------------PL_KEY/系统复位---------------------------
set_property -dict {PACKAGE_PIN J15 IOSTANDARD LVCMOS33} [get_ports sys_rst_n]

#----------------------PL_LED---------------------------
set_property -dict {PACKAGE_PIN G14 IOSTANDARD LVCMOS33} [get_ports {led}]

#----------------------LCD接口---------------------------
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
set_property -dict {PACKAGE_PIN N17 IOSTANDARD LVCMOS33} [get_ports lcd_clk]
set_property -dict {PACKAGE_PIN T19 IOSTANDARD LVCMOS33} [get_ports lcd_rst]

#lcd_scl:
set_property -dict {PACKAGE_PIN M19 IOSTANDARD LVCMOS33} [get_ports lcd_scl]
#lcd_sda:
set_property -dict {PACKAGE_PIN M20 IOSTANDARD LVCMOS33} [get_ports lcd_sda]
#CT_RST
set_property -dict {PACKAGE_PIN U19 IOSTANDARD LVCMOS33} [get_ports ct_rst]
#CT_INT
set_property -dict {PACKAGE_PIN N20 IOSTANDARD LVCMOS33} [get_ports ct_int]

#---------------------LCD TOUCH---------------------------
set_property -dict {PACKAGE_PIN M19 IOSTANDARD LVCMOS33} [get_ports touch_scl]
set_property -dict {PACKAGE_PIN M20 IOSTANDARD LVCMOS33} [get_ports touch_sda]
set_property -dict {PACKAGE_PIN U19 IOSTANDARD LVCMOS33} [get_ports touch_int]
set_property -dict {PACKAGE_PIN N20 IOSTANDARD LVCMOS33} [get_ports touch_rst]

#----------------------HDMI接口---------------------------
set_property -dict {PACKAGE_PIN J20  IOSTANDARD TMDS_33 } [get_ports {tmds_data_p[2]}]
set_property -dict {PACKAGE_PIN K19  IOSTANDARD TMDS_33 } [get_ports {tmds_data_p[1]}]
set_property -dict {PACKAGE_PIN G19  IOSTANDARD TMDS_33 } [get_ports {tmds_data_p[0]}]
set_property -dict {PACKAGE_PIN J18  IOSTANDARD TMDS_33 } [get_ports tmds_clk_p]

set_property -dict {PACKAGE_PIN M19  IOSTANDARD LVCMOS33} [get_ports tmds_scl]
set_property -dict {PACKAGE_PIN M20  IOSTANDARD LVCMOS33} [get_ports tmds_sda]
set_property -dict {PACKAGE_PIN L19  IOSTANDARD LVCMOS33} [get_ports tmds_hpd]


