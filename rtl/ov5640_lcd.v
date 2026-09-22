//****************************************Copyright (c)***********************************//
//原子哥在线教学平台：www.yuanzige.com
//技术支持：http://www.openedv.com/forum.php
//淘宝店铺：https://zhengdianyuanzi.tmall.com
//关注微信公众平台微信号："正点原子"，免费获取ZYNQ & FPGA & STM32 & LINUX资料。
//版权所有，盗版必究。
//Copyright(C) 正点原子 2023-2033
//All rights reserved         
//----------------------------------------------------------------------------------------
// File name:           ov5640_lcd
// Created by:          正点原子
// Created date:        2025年12月04日14:20:02
// Version:             V1.0
// Descriptions:        OV5640摄像头LCD显示
//                      
//----------------------------------------------------------------------------------------
//****************************************************************************************//

module ov5640_lcd(    
    input      [3:0]      key          ,  //按键(低电平有效)
    output     [3:0]      led          ,  //LED指示(低电平点亮)
    input                 sys_clk      ,  //系统时钟
    input                 sys_rst_n    ,  //系统复位，低电平有效
    //摄像头接口                       
    input                 cam_pclk     ,  //cmos数据像素时钟
    input                 cam_vsync    ,  //cmos场同步信号
    input                 cam_href     ,  //cmos行同步信号
    input   [7:0]         cam_data     ,  //cmos数据
    output                cam_rst_n    ,  //cmos复位信号，低电平有效
    output                cam_pwdn ,      //电源休眠模式选择 0：正常模式 1：电源休眠模式
    output                cam_scl      ,  //cmos SCCB_SCL线
    inout                 cam_sda      ,  //cmos SCCB_SDA线
    // DDR3                            
    inout   [15:0]        ddr3_dq      ,  //DDR3数据
    inout   [1:0]         ddr3_dqs_n   ,  //DDR3 dqs负
    inout   [1:0]         ddr3_dqs_p   ,  //DDR3 dqs正
    output  [13:0]        ddr3_addr    ,  //DDR3地址
    output  [2:0]         ddr3_ba      ,  //DDR3 bank选择
    output                ddr3_ras_n   ,  //DDR3行选择
    output                ddr3_cas_n   ,  //DDR3列选择
    output                ddr3_we_n    ,  //DDR3读写选择
    output                ddr3_reset_n ,  //DDR3复位
    output  [0:0]         ddr3_ck_p    ,  //DDR3时钟正
    output  [0:0]         ddr3_ck_n    ,  //DDR3时钟负
    output  [0:0]         ddr3_cke     ,  //DDR3时钟使能
    output  [0:0]         ddr3_cs_n    ,  //DDR3片选
    output  [1:0]         ddr3_dm      ,  //DDR3_dm
    output  [0:0]         ddr3_odt     ,  //DDR3_odt
    //lcd接口
    output                lcd_hs       ,  //LCD 行同步信号
    output                lcd_vs       ,  //LCD 场同步信号
    output                lcd_de       ,  //LCD 数据输入使能
    inout       [23:0]    lcd_rgb      ,  //LCD 颜色数据
    output                lcd_bl       ,  //LCD 背光控制信号
    output                lcd_rst      ,  //LCD 复位信号
    output                lcd_pclk        //LCD 采样时钟
    );

//wire define
wire         clk_50m                   ;  //50MHz时钟,提供给LCD驱动时钟
wire         locked                    ;  //时钟锁定信号
wire         rst_n                     ;  //全局复位
wire  [15:0] wrdata                    ;  //DDR3控制器模块写数据
wire         rdata_req                 ;  //DDR3控制器模块读使能
wire  [15:0] rddata                    ;  //DDR3控制器模块读数据
wire         cmos_frame_valid          ;  //数据有效使能信号
wire         init_calib_complete       ;  //DDR3初始化完成init_calib_complete
wire         sys_init_done             ;  //系统初始化完成(DDR初始化+摄像头初始化)
wire         clk_200m                  ;  //DDR3参考时钟
wire         cmos_frame_vsync          ;  //输出帧有效场同步信号
wire         lcd_clk                   ;  //分频产生的LCD 采样时钟
wire  [12:0] h_disp                    ;  //LCD屏水平分辨率
wire  [12:0] v_disp                    ;  //LCD屏垂直分辨率
wire  [12:0] y_addr_st                 ;
wire  [12:0] y_addr_end                ;
wire  [15:0] lcd_id                    ;  //LCD屏的ID号
wire  [27:0] ddr3_addr_max             ;  //存入DDR3的最大读写地址
wire  [12:0] total_h_pixel             ;  //水平总像素大小
wire  [12:0] total_v_pixel             ;  //垂直总像素大小
wire         rd_vsync                 ;  //帧起始脉冲(LCD场信号)
wire  [15:0] lcd_data                 ;  //视觉处理后送LCD的像素
wire         vision_bond_valid        ;  //侦测到装甲板
wire  [9:0]  vision_cx                ;  //装甲板中心x
wire  [9:0]  vision_cy                ;  //装甲板中心y

//*****************************************************
//**                    main code
//*****************************************************

//待时钟锁定后产生复位结束信号
assign  rst_n = sys_rst_n & locked;

//系统初始化完成：DDR3初始化完成
assign  sys_init_done = init_calib_complete;

//摄像头图像分辨率设置模块
picture_size u_picture_size (
    .rst_n              (rst_n         ),
    .clk                (clk_50m       ),
    .lcd_id             (lcd_id        ), //LCD的器件ID
                        
    .cmos_h_pixel       (h_disp        ), //摄像头水平分辨率
    .cmos_v_pixel       (v_disp        ), //摄像头垂直分辨率
    .total_h_pixel      (total_h_pixel ), //水平总像素大小
    .total_v_pixel      (total_v_pixel ), //垂直总像素大小
    .y_addr_st          (y_addr_st     ),
    .y_addr_end         (y_addr_end    ),
    .ddr3_addr_max      (ddr3_addr_max )  //DDR3最大读写地址
    );

//ov5640 驱动
ov5640_dri u_ov5640_dri(
    .clk               (clk_50m            ),
    .rst_n             (rst_n              ),

    .cam_pclk          (cam_pclk           ),
    .cam_vsync         (cam_vsync          ),
    .cam_href          (cam_href           ),
    .cam_data          (cam_data           ),
    .cam_rst_n         (cam_rst_n          ),
    .cam_pwdn          (cam_pwdn           ),
    .cam_scl           (cam_scl            ),
    .cam_sda           (cam_sda            ),

    .capture_start     (init_calib_complete),
    .cmos_h_pixel      (h_disp             ),
    .cmos_v_pixel      (v_disp             ),
    .total_h_pixel     (total_h_pixel      ),
    .total_v_pixel     (total_v_pixel      ),
    .y_addr_st         (y_addr_st          ),
    .y_addr_end        (y_addr_end         ),
    .cmos_frame_vsync  (cmos_frame_vsync   ),
    .cmos_frame_href   (                   ),
    .cmos_frame_valid  (cmos_frame_valid   ),
    .cmos_frame_data   (wrdata             )
    );

ddr3_top u_ddr3_top(
    .rst_n                 (rst_n              ),//复位,低有效
    .init_calib_complete   (init_calib_complete),//ddr3初始化完成信号
    //ddr3接口信号
    .app_addr_rd_min       (28'd0              ),//读DDR3的起始地址
    .app_addr_rd_max       (ddr3_addr_max[27:0]),//读DDR3的结束地址
    .rd_bust_len           (h_disp[10:3]       ),//从DDR3中读数据时的突发长度
    .app_addr_wr_min       (28'd0              ),//写DDR3的起始地址
    .app_addr_wr_max       (ddr3_addr_max[27:0]),//写DDR3的结束地址
    .wr_bust_len           (h_disp[10:3]       ),//从DDR3中写数据时的突发长度
    // DDR3 IO接口
    .ddr3_dq               (ddr3_dq            ),//DDR3数据
    .ddr3_dqs_n            (ddr3_dqs_n         ),//DDR3 dqs负
    .ddr3_dqs_p            (ddr3_dqs_p         ),//DDR3 dqs正
    .ddr3_addr             (ddr3_addr          ),//DDR3地址
    .ddr3_ba               (ddr3_ba            ),//DDR3 bank选择
    .ddr3_ras_n            (ddr3_ras_n         ),//DDR3行选择
    .ddr3_cas_n            (ddr3_cas_n         ),//DDR3列选择
    .ddr3_we_n             (ddr3_we_n          ),//DDR3读写选择
    .ddr3_reset_n          (ddr3_reset_n       ),//DDR3复位
    .ddr3_ck_p             (ddr3_ck_p          ),//DDR3时钟正
    .ddr3_ck_n             (ddr3_ck_n          ),//DDR3时钟负
    .ddr3_cke              (ddr3_cke           ),//DDR3时钟使能
    .ddr3_cs_n             (ddr3_cs_n          ),//DDR3片选
    .ddr3_dm               (ddr3_dm            ),//DDR3_dm
    .ddr3_odt              (ddr3_odt           ),//DDR3_odt
    // System Clock Ports
    .sys_clk_i             (clk_200m),
    // Reference Clock Ports
    .clk_ref_i             (clk_200m),
    //用户
    .ddr3_read_valid       (1'b1            ),//DDR3读使能
    .ddr3_pingpang_en      (1'b1            ),//DDR3乒乓操作使能
    .wr_clk                (cam_pclk        ),//写时钟
    .wr_load               (cmos_frame_vsync),//输入源更新信号
    .wr_en                 (cmos_frame_valid),//数据有效使能信号
    .wrdata                (wrdata          ),//写有效数据
    .rd_clk                (lcd_clk         ),//读时钟
    .rd_load               (rd_vsync        ),//输出源更新信号
    .rddata                (rddata          ),//rfifo输出数据
    .rdata_req             (rdata_req       ) //请求数据输入
     );

//例化时钟IP核
clk_wiz_0 u_clk_wiz_0
   (
    // Clock out ports
    .clk_out1              (clk_200m  ),
    .clk_out2              (clk_50m   ),
    // Status and control signals
    .reset                 (~sys_rst_n),
    .locked                (locked    ),
   // Clock in ports
    .clk_in1               (sys_clk   )
    );

//LCD驱动显示模块
lcd_rgb_top  u_lcd_rgb_top(
    .sys_clk        (clk_50m      ),
    .sys_rst_n      (rst_n        ),
    .sys_init_done  (sys_init_done),

    //LCD接口
    .lcd_id         (lcd_id   ),//LCD屏的ID号
    .lcd_hs         (lcd_hs   ),//LCD 行同步信号
    .lcd_vs         (lcd_vs   ),//LCD 场同步信号
    .lcd_de         (lcd_de   ),//LCD 数据输入使能
    .lcd_rgb        (lcd_rgb  ),//LCD 颜色数据
    .lcd_bl         (lcd_bl   ),//LCD 背光控制信号
    .lcd_rst        (lcd_rst  ),//LCD 复位信号
    .lcd_pclk       (lcd_pclk ),//LCD 采样时钟
    .lcd_clk        (lcd_clk  ),//LCD 驱动时钟
    //用户接口              
    .out_vsync      (rd_vsync ),//LCD场信号
    .h_disp         (         ),//行分辨率
    .v_disp         (         ),//场分辨率
    .pixel_xpos     (         ),
    .pixel_ypos     (         ),
    .data_in        (lcd_data   ),//rfifo输出数据
    .data_req       (rdata_req) //请求数据输入
    );


//*****************************************************
//**  视觉处理：颜色分割 -> 形态学 -> 投影 -> 画框/十字
//**  说明文件：README.md / doc/vision_pipeline.md
//*****************************************************

armor_vision u_armor_vision(
    .clk        (lcd_clk          ),//像素时钟
    .rst_n      (rst_n            ),//复位
    .vsync      (rd_vsync         ),//帧起始脉冲
    .de         (rdata_req        ),//像素有效
    .data_in    (rddata           ),//DDR3读出的像素
    .key        (key              ),//按键
    .data_out   (lcd_data         ),//处理后像素
    .led        (led              ),//LED指示
    .bond_valid (vision_bond_valid),//侦测结果
    .center_x   (vision_cx        ),
    .center_y   (vision_cy        )
);
endmodule