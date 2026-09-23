//****************************************Copyright (c)***********************************//
// File name:           seg_display
// Descriptions:        6 位数码管显示（绿色靶标的三个阈值 / 目标尺寸）
//
//   硬件：正点原子达芬奇 XC7A35T 板载 6 位【共阳】数码管
//         seg_sel[5:0] = 位选，低电平选通该位
//         seg_led[7:0] = 段码 {dp,g,f,e,d,c,b,a}，低电平点亮
//
//   【显示内容】位序 dig0 = 最右边一位
//
//        dig5 : 当前选中的阈值编号（1 / 2 / 3）
//               —— 这一位的小数点点亮 = 当前是【纯二值图】显示模式
//        dig4 : 选中阈值的百位
//        dig3 : 选中阈值的十位
//        dig2 : 选中阈值的个位          （所以阈值范围 000~255 都能显示）
//        dig1 : 目标边界框宽度 / 10 的十位
//        dig0 : 目标边界框宽度 / 10 的个位
//               —— 没检测到目标时这两位熄灭
//
//   例：010 3 2 7 1 9  ->  阈值编号 3，阈值 010，目标宽 199 像素
//
//   动扫：每位 SCAN_HZ（默认 1kHz），6 位合计约 166Hz，不会闪。
//----------------------------------------------------------------------------------------
//****************************************************************************************//

`timescale 1ns / 1ps

module seg_display #(
    parameter CLK_FREQ = 25_000_000,   // 工作时钟频率
    parameter SCAN_HZ  = 1000      ,   // 每位刷新率
    parameter SEG_REV  = 1'b0          // 1 = 位选顺序反过来（seg_sel[0] 是最左一位）
)(
    input             clk       ,   // 时钟
    input             rst_n     ,   // 复位
    input      [1:0]  sel       ,   // 当前选中的阈值编号 0/1/2
    input      [7:0]  th_g      ,   // TH_G
    input      [7:0]  th_gr     ,   // TH_G-R
    input      [7:0]  th_gb     ,   // TH_G-B
    input             bond_valid,   // 是否检测到目标
    input      [10:0] bond_w    ,   // 目标边界框宽度（像素）
    input             disp_bin  ,   // 纯二值显示模式
    output reg [5:0]  seg_sel   ,   // 位选（低电平选通）
    output reg [7:0]  seg_led       // 段码（低电平点亮）
);

//localparam define
localparam DIV = CLK_FREQ / SCAN_HZ;   // 每位持续多少个时钟

//reg define
reg [15:0] div_cnt;   // 分频计数
reg [2:0]  dig    ;   // 当前扫到第几位

//wire define
// 只用十进制常量做除法，Vivado 会用常数乘法实现，很省
wire [7:0]  cur_val = (sel == 2'd0) ? th_g : ((sel == 2'd1) ? th_gr : th_gb);
wire [3:0]  v_h     = cur_val / 8'd100;             // 百位
wire [3:0]  v_t     = (cur_val / 8'd10) % 8'd10;    // 十位
wire [3:0]  v_o     = cur_val % 8'd10;              // 个位
wire [3:0]  v_idx   = {2'b00, sel} + 4'd1;          // 编号 1/2/3

wire [10:0] w10 = bond_w / 11'd10;                  // 宽度 / 10
wire [3:0]  w_t = w10 / 11'd10;
wire [3:0]  w_o = w10 % 11'd10;

// 4'hF = 熄灭
wire [3:0] d0 = bond_valid ? w_o   : 4'hF;
wire [3:0] d1 = bond_valid ? w_t   : 4'hF;
wire [3:0] d2 = v_o;
wire [3:0] d3 = v_t;
wire [3:0] d4 = v_h;
wire [3:0] d5 = v_idx;

// dig5 的小数点：亮 = 纯二值显示模式
wire       dp5    = disp_bin;
wire [2:0] dig_of = SEG_REV ? (3'd5 - dig) : dig;

//-------------------------------------------------------
// 共阳数码管段码 {dp,g,f,e,d,c,b,a}，低电平点亮
//-------------------------------------------------------
function [7:0] seg7;
    input [3:0] v;
    begin
        case(v)
            4'd0: seg7 = 8'hC0;
            4'd1: seg7 = 8'hF9;
            4'd2: seg7 = 8'hA4;
            4'd3: seg7 = 8'hB0;
            4'd4: seg7 = 8'h99;
            4'd5: seg7 = 8'h92;
            4'd6: seg7 = 8'h82;
            4'd7: seg7 = 8'hF8;
            4'd8: seg7 = 8'h80;
            4'd9: seg7 = 8'h90;
            default: seg7 = 8'hFF;   // 4'hF -> 全灭
        endcase
    end
endfunction

//*****************************************************
//**                    main code
//*****************************************************

//-------------------------------------------------------
// 扫描分频 + 位计数
//-------------------------------------------------------
always @(posedge clk or negedge rst_n) begin
    if(!rst_n) begin
        div_cnt <= 16'd0;
        dig     <= 3'd0;
    end
    else if(div_cnt >= (DIV - 1)) begin
        div_cnt <= 16'd0;
        dig     <= (dig == 3'd5) ? 3'd0 : (dig + 1'b1);
    end
    else
        div_cnt <= div_cnt + 1'b1;
end

//-------------------------------------------------------
// 段码 / 位选输出
//-------------------------------------------------------
always @(*) begin
    case(dig_of)
        3'd0: begin seg_led = seg7(d0); seg_sel = 6'b111110; end
        3'd1: begin seg_led = seg7(d1); seg_sel = 6'b111101; end
        3'd2: begin seg_led = seg7(d2); seg_sel = 6'b111011; end
        3'd3: begin seg_led = seg7(d3); seg_sel = 6'b110111; end
        3'd4: begin seg_led = seg7(d4); seg_sel = 6'b101111; end
        default: begin
            // dig5：带「显示模式」小数点
            seg_led = dp5 ? (seg7(d5) & 8'h7F) : seg7(d5);
            seg_sel = 6'b011111;
        end
    endcase
end

endmodule
