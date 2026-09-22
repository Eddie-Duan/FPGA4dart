//****************************************Copyright (c)***********************************//
// File name:           key_debounce
// Descriptions:        按键消抖 + 按下沿检测（按键低电平有效）
//                      - 输入先打两拍同步，避免亚稳态
//                      - 连续稳定 DEBOUNCE_MS 毫秒才更新按键状态
//                      - 检测到“按下”时输出一个时钟的脉冲 press
//----------------------------------------------------------------------------------------
//****************************************************************************************//
`timescale 1ns / 1ps

module key_debounce #(
    parameter CLK_FREQ    = 25_000_000,   // 工作时钟频率
    parameter DEBOUNCE_MS = 20            // 消抖时间（毫秒）
)(
    input      clk      ,   // 时钟
    input      rst_n    ,   // 复位，低电平有效
    input      key_in   ,   // 按键输入（低电平有效）
    output reg press        // 按下时输出一个时钟的脉冲
);

//localparam define
localparam CNT_MAX = (CLK_FREQ/1000)*DEBOUNCE_MS;   // 消抖计数最大值
localparam CNT_W   = $clog2(CNT_MAX+1);             // 计数器位宽

//reg define
reg  [1:0]       key_sync ;   // 按键同步寄存器
reg              key_stable;  // 消抖后的稳定值
reg  [CNT_W-1:0] cnt      ;   // 消抖计数器

//*****************************************************
//**                    main code
//*****************************************************

always @(posedge clk or negedge rst_n) begin
    if(!rst_n) begin
        key_sync   <= 2'b11;
        key_stable <= 1'b1;
        cnt        <= {CNT_W{1'b0}};
        press      <= 1'b0;
    end
    else begin
        key_sync <= {key_sync[0], key_in};   // 打两拍同步

        press <= 1'b0;                       // 默认输出为 0（只维持一拍）

        if(key_sync[1] != key_stable) begin  // 输入发生变化，开始计时
            if(cnt == CNT_MAX-1) begin
                cnt        <= {CNT_W{1'b0}};
                key_stable <= key_sync[1];
                if(key_sync[1] == 1'b0)      // 1->0 表示按下
                    press <= 1'b1;
            end
            else
                cnt <= cnt + 1'b1;
        end
        else
            cnt <= {CNT_W{1'b0}};            // 电平稳定，计数器归零
    end
end

endmodule
