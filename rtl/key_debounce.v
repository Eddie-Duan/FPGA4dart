//****************************************Copyright (c)***********************************//
// File name:           key_debounce
// Descriptions:        按鍵消抖 + 按下沿檢測（按鍵低電平有效）
//                      - 輸入先打兩拍同步，避免亞穩態
//                      - 連續穩定 DEBOUNCE_MS 毫秒才更新按鍵狀態
//                      - 偵測到「按下」時輸出一個時鐘的脈衝 press
//----------------------------------------------------------------------------------------
//****************************************************************************************//
`timescale 1ns / 1ps

module key_debounce #(
    parameter CLK_FREQ    = 25_000_000,   // 工作時鐘頻率
    parameter DEBOUNCE_MS = 20            // 消抖時間（毫秒）
)(
    input      clk      ,   // 時鐘
    input      rst_n    ,   // 復位，低電平有效
    input      key_in   ,   // 按鍵輸入（低電平有效）
    output reg press        // 按下時輸出一個時鐘的脈衝
);

//localparam define
localparam CNT_MAX = (CLK_FREQ/1000)*DEBOUNCE_MS;   // 消抖計數最大值
localparam CNT_W   = $clog2(CNT_MAX+1);             // 計數器位寬

//reg define
reg  [1:0]       key_sync ;   // 按鍵同步寄存器
reg              key_stable;  // 消抖後的穩定值
reg  [CNT_W-1:0] cnt      ;   // 消抖計數器

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
        key_sync <= {key_sync[0], key_in};   // 打兩拍同步

        press <= 1'b0;                       // 預設輸出為 0（只維持一拍）

        if(key_sync[1] != key_stable) begin  // 輸入發生變化，開始計時
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
            cnt <= {CNT_W{1'b0}};            // 電平穩定，計數器歸零
    end
end

endmodule
