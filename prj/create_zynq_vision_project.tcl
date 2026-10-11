set script_dir [file dirname [file normalize [info script]]]
set repo_root [file normalize [file join $script_dir ..]]
set project_dir [file join $script_dir zynq_vision]

create_project -force zynq_vision $project_dir -part xc7z020clg400-2
set_property target_language Verilog [current_project]
set_property simulator_language Mixed [current_project]

add_files -norecurse [glob [file join $repo_root rtl *.v]]
set_property top ov5640_lcd_zynq [current_fileset]
set_property top_auto_set 0 [current_fileset]

foreach fifo {wr_fifo rd_fifo} {
    set fifo_dir [file join $project_dir ip $fifo]
    file mkdir $fifo_dir
    create_ip -name fifo_generator -vendor xilinx.com -library ip -version 13.2 \
        -module_name $fifo -dir $fifo_dir
    set_property -dict [list \
        CONFIG.Fifo_Implementation {Independent_Clocks_Block_RAM} \
        CONFIG.Input_Data_Width {128} \
        CONFIG.Input_Depth {1024} \
        CONFIG.Output_Data_Width {128} \
        CONFIG.Output_Depth {1024} \
        CONFIG.Performance_Options {First_Word_Fall_Through} \
        CONFIG.Output_Register_Type {Embedded_Reg} \
        CONFIG.Read_Data_Count {true} \
        CONFIG.Read_Data_Count_Width {10} \
        CONFIG.Write_Data_Count {true} \
        CONFIG.Write_Data_Count_Width {10} \
        CONFIG.Enable_Reset_Synchronization {true} \
        CONFIG.Reset_Type {Asynchronous_Reset} \
    ] [get_ips $fifo]
    generate_target all [get_ips $fifo]
    set_property generate_synth_checkpoint 0 [get_files ${fifo}.xci]
}

add_files -fileset constrs_1 -norecurse [file join $script_dir zynq_challenger.xdc]
update_compile_order -fileset sources_1

create_bd_design system
set ps [create_bd_cell -type ip -vlnv xilinx.com:ip:processing_system7:5.5 processing_system7_0]
set_property -dict [list \
    CONFIG.PCW_USE_M_AXI_GP0 {0} \
    CONFIG.PCW_USE_S_AXI_HP0 {1} \
    CONFIG.PCW_S_AXI_HP0_DATA_WIDTH {64} \
    CONFIG.PCW_S_AXI_HP0_ID_WIDTH {6} \
    CONFIG.PCW_EN_CLK0_PORT {1} \
    CONFIG.PCW_EN_CLK1_PORT {1} \
    CONFIG.PCW_FPGA0_PERIPHERAL_FREQMHZ {100} \
    CONFIG.PCW_FPGA1_PERIPHERAL_FREQMHZ {50} \
    CONFIG.PCW_EN_RST0_PORT {1} \
    CONFIG.PCW_UIPARAM_DDR_MEMORY_TYPE {DDR 3 (Low Voltage)} \
    CONFIG.PCW_UIPARAM_DDR_PARTNO {MT41K256M16 RE-125} \
    CONFIG.PCW_UIPARAM_DDR_BUS_WIDTH {32 Bit} \
    CONFIG.PCW_UIPARAM_DDR_DEVICE_CAPACITY {4096 MBits} \
    CONFIG.PCW_UIPARAM_DDR_FREQ_MHZ {533.333333} \
    CONFIG.PCW_UIPARAM_DDR_SPEED_BIN {DDR3_1066F} \
    CONFIG.PCW_UIPARAM_DDR_ROW_ADDR_COUNT {15} \
    CONFIG.PCW_UIPARAM_DDR_COL_ADDR_COUNT {10} \
    CONFIG.PCW_UIPARAM_DDR_BANK_ADDR_COUNT {3} \
] $ps

set vision [create_bd_cell -type module -reference ov5640_lcd_zynq vision_top]

connect_bd_intf_net [get_bd_intf_pins $vision/M_AXI] [get_bd_intf_pins $ps/S_AXI_HP0]
connect_bd_net [get_bd_pins $ps/FCLK_CLK0] [get_bd_pins $ps/S_AXI_HP0_ACLK] [get_bd_pins $vision/ui_clk]
connect_bd_net [get_bd_pins $ps/FCLK_CLK1] [get_bd_pins $vision/lcd_sys_clk]
set reset_ctl [create_bd_cell -type ip -vlnv xilinx.com:ip:proc_sys_reset:5.0 rst_ps7_0_100M]
connect_bd_net [get_bd_pins $ps/FCLK_CLK0] [get_bd_pins $reset_ctl/slowest_sync_clk]
connect_bd_net [get_bd_pins $ps/FCLK_RESET0_N] [get_bd_pins $reset_ctl/ext_reset_in]
connect_bd_net [get_bd_pins $reset_ctl/peripheral_aresetn] [get_bd_pins $vision/rst_n]
assign_bd_address -offset 0x00000000 -range 0x40000000 \
    -target_address_space [get_bd_addr_spaces $vision/M_AXI] \
    [get_bd_addr_segs $ps/S_AXI_HP0/HP0_DDR_LOWOCM] -force

make_bd_intf_pins_external -name DDR [get_bd_intf_pins $ps/DDR]
make_bd_intf_pins_external -name FIXED_IO [get_bd_intf_pins $ps/FIXED_IO]

foreach pin {
    cam_pclk cam_vsync cam_href cam_data cam_rst_n cam_pwdn cam_scl cam_sda
    lcd_hs lcd_vs lcd_de lcd_bl lcd_rst lcd_pclk lcd_rgb
    led uart_rxd uart_txd
} {
    make_bd_pins_external -name $pin [get_bd_pins $vision/$pin]
}

validate_bd_design
save_bd_design
generate_target all [get_files [file join $project_dir zynq_vision.srcs sources_1 bd system system.bd]]

set bd_file [get_files [file join $project_dir zynq_vision.srcs sources_1 bd system system.bd]]
set wrapper_file [make_wrapper -files $bd_file -top]
add_files -norecurse $wrapper_file
set_property top system_wrapper [current_fileset]
set_property top_auto_set 0 [current_fileset]
update_compile_order -fileset sources_1

launch_runs synth_1 -jobs 4
wait_on_run synth_1
set synth_status [get_property STATUS [get_runs synth_1]]
if {![string match "*Complete*" $synth_status]} {
    error "Zynq synthesis failed: $synth_status"
}

puts "Created and synthesized [file join $project_dir zynq_vision.xpr]"
