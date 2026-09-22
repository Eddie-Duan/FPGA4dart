//****************************************Copyright (c)***********************************//
// File name:           vision_cfg
// Descriptions:        視覺參數控制（四個按鍵）
//
//   key[0] : 紅 / 藍 切換
//   key[1] : 顏色門檻 +8（飽和到 255）
//   key[2] : 顏色門檻 -8（下限 0）
//   key[3] : 顯示模式切換（0 = 原圖變暗+標記；1 = 純二值圖）
//
//   按鍵在板上是低電平有效，且與 lcd_clk 不同步，
//   因此每顆按鍵都過一級 key_debounce（內含同步 + 20ms 消抖 + 按下沿）。
//----------------------------------------------------------------------------------------
//****************************************************************************************//
`timescale 1ns / 1ps

module vision_cfg #(
    parameter CLK_FREQ = 25_000_000     // 工作時鐘頻率（要和實際 lcd_clk 相符）
)(
    input             clk     ,   // 時鐘
    input             rst_n   ,   // 復位
    input      [3:0]  key     ,   // 按鍵（低電平有效）
    output reg        mode    ,   // 0 = 紅，1 = 藍
    output reg [7:0]  thresh  ,   // 顏色分割門檻
    output reg        disp_bin    // 顯示模式
);

//wire define
wire [3:0] press;   // 各按鍵的「按下」脈衝

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
        thresh   <= 8'd40;      // 預設門檻
        disp_bin <= 1'b0;
    end
    else begin
        if(press[0])                       // 紅 / 藍 切換
            mode <= ~mode;

        if(press[1])                       // 門檻加大
            thresh <= (thresh > 8'd247) ? 8'd255 : (thresh + 8'd8);
        else if(press[2])                  // 門檻減小
            thresh <= (thresh < 8'd8) ? 8'd0 : (thresh - 8'd8);

        if(press[3])                       // 顯示模式
            disp_bin <= ~disp_bin;
    end
end

endmodule
