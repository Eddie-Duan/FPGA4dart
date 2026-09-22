//****************************************Copyright (c)***********************************//
// File name:           vision_cfg
// Descriptions:        视觉参数控制（四个按键）
//
//   key[0] : 红 / 蓝 切换
//   key[1] : 颜色阈值 +8（饱和到 255）
//   key[2] : 颜色阈值 -8（下限 0）
//   key[3] : 显示模式切换（0 = 原图变暗+标记；1 = 纯二值图）
//
//   按键在板上是低电平有效，且与 lcd_clk 不同步，
//   因此每颗按键都过一级 key_debounce（内含同步 + 20ms 消抖 + 按下沿）。
//----------------------------------------------------------------------------------------
//****************************************************************************************//
`timescale 1ns / 1ps

module vision_cfg #(
    parameter CLK_FREQ = 25_000_000     // 工作时钟频率（要和实际 lcd_clk 相符）
)(
    input             clk     ,   // 时钟
    input             rst_n   ,   // 复位
    input      [3:0]  key     ,   // 按键（低电平有效）
    output reg        mode    ,   // 0 = 红，1 = 蓝
    output reg [7:0]  thresh  ,   // 颜色分割阈值
    output reg        disp_bin    // 显示模式
);

//wire define
wire [3:0] press;   // 各按键的“按下”脉冲

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

always @(posedge clk or negedge rst_n) begin
    if(!rst_n) begin
        mode     <= 1'b0;
        thresh   <= 8'd40;      // 默认阈值
        disp_bin <= 1'b0;
    end
    else begin
        if(press[0])                       // 红 / 蓝 切换
            mode <= ~mode;

        if(press[1])                       // 阈值加大
            thresh <= (thresh > 8'd247) ? 8'd255 : (thresh + 8'd8);
        else if(press[2])                  // 阈值减小
            thresh <= (thresh < 8'd8) ? 8'd0 : (thresh - 8'd8);

        if(press[3])                       // 显示模式
            disp_bin <= ~disp_bin;
    end
end

endmodule
