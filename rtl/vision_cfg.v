//****************************************Copyright (c)***********************************//
// File name:           vision_cfg
// Descriptions:        视觉参数控制（四颗按键，绿色靶标三个阈值）
//
//   【按键新分工】——原来是「红/蓝切换 + 一个阈值加减」，现在绿色判据有 3 个阈值，
//   所以 key[0] 改成「选哪个阈值」，key[1]/key[2] 对这一颗做加减：
//
//     key[0] : 循环选择要调的阈值   0 = TH_G（绿色亮度下限）
//                                  1 = TH_G-R（G-R 差值下限）
//                                  2 = TH_G-B（G-B 差值下限）
//     key[1] : 当前选中的阈值 +8（饱和到 255）
//     key[2] : 当前选中的阈值 -8（下限到 0）
//     key[3] : 显示模式切换（0 = 原图变暗 + 标记；1 = 纯二值图）
//
//   默认值取自 dart 专案（10bit 下 400 / 130 / 130）折算到 8bit：100 / 32 / 32。
//   当前值会在 6 位数码管上显示（seg_display.v），不用接串口。
//
//   按键是低电平有效，先在 lcd_clk 下同步，再用 key_debounce 做 20ms 消抖 + 取按下沿。
//----------------------------------------------------------------------------------------
//****************************************************************************************//

`timescale 1ns / 1ps

module vision_cfg #(
    parameter CLK_FREQ  = 25_000_000,   // 工作时钟频率（必须和实际 lcd_clk 一致）
    parameter TH_G_DEF  = 8'd100    ,   // TH_G  默认值
    parameter TH_GR_DEF = 8'd32     ,   // TH_G-R 默认值
    parameter TH_GB_DEF = 8'd32         // TH_G-B 默认值
)(
    input             clk     ,   // 时钟
    input             rst_n   ,   // 复位
    input      [3:0]  key     ,   // 按键（低电平有效）
    output reg [1:0]  sel     ,   // 当前选中的阈值编号 0/1/2
    output reg [7:0]  th_g    ,   // 绿色亮度下限
    output reg [7:0]  th_gr   ,   // G-R 差值下限
    output reg [7:0]  th_gb   ,   // G-B 差值下限
    output reg        disp_bin    // 显示模式
);

//wire define
wire [3:0] press;   // 每颗按键的「按下」脉冲

//*****************************************************
//**                    main code
//*****************************************************

genvar i;
generate
    for(i=0; i<4; i=i+1) begin : gen_key
        key_debounce #(
            .CLK_FREQ    (CLK_FREQ),
            .DEBOUNCE_MS (20)
        ) u_key_debounce (
            .clk    (clk      ),
            .rst_n  (rst_n    ),
            .key_in (key[i]   ),
            .press  (press[i] )
        );
    end
endgenerate

//-------------------------------------------------------
// 三个阈值 + 选择 + 显示模式
//   同一拍里 press[1] 优先于 press[2]（消抖后同时按下的概率极低）
//-------------------------------------------------------
always @(posedge clk or negedge rst_n) begin
    if(!rst_n) begin
        sel      <= 2'd0;
        th_g     <= TH_G_DEF;
        th_gr    <= TH_GR_DEF;
        th_gb    <= TH_GB_DEF;
        disp_bin <= 1'b0;
    end
    else begin
        // key[0]：0 -> 1 -> 2 -> 0 循环
        if(press[0])
            sel <= (sel == 2'd2) ? 2'd0 : (sel + 1'b1);

        // key[3]：显示模式
        if(press[3])
            disp_bin <= ~disp_bin;

        // key[1]/key[2]：只改当前选中的那一颗
        if(press[1] || press[2]) begin
            case(sel)
                2'd0: th_g  <= press[1] ? ((th_g  > 8'd247) ? 8'd255 : (th_g  + 8'd8))
                                        : ((th_g  < 8'd8  ) ? 8'd0   : (th_g  - 8'd8));
                2'd1: th_gr <= press[1] ? ((th_gr > 8'd247) ? 8'd255 : (th_gr + 8'd8))
                                        : ((th_gr < 8'd8  ) ? 8'd0   : (th_gr - 8'd8));
                default: th_gb <= press[1] ? ((th_gb > 8'd247) ? 8'd255 : (th_gb + 8'd8))
                                           : ((th_gb < 8'd8  ) ? 8'd0   : (th_gb - 8'd8));
            endcase
        end
    end
end

endmodule
