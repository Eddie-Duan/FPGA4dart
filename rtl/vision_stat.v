`timescale 1ns / 1ps
//****************************************************************************************//
// File name:           vision_stat
// Descriptions:        视觉管线仪表盘：帧率 / 帧长 / 掩码像素数 / 命中率（P0）
//
//   纯观测模块。只读信号、只输出统计量，不参与任何判决，不改动画面与检测结果。
//   目的：让后续每一步改动都能被量化 —— 否则调参只能靠猜。
//
//   测量项（每帧结束更新一次）：
//     frame_cyc    上一帧周期，单位 clk（lcd_clk 25MHz）。800x480 时约 554400
//     fps          1 秒窗口内数到的帧数 —— 真平均数，不需要除法器
//     frame_lines  上一帧的有效行数（应为 480，可核对传感器模式 / 有没有丢行）
//     mask_cnt     上一帧通过颜色判据的像素数 —— 调阈值最直接的指标
//     hit_frames   累计「检测到目标」帧数（饱和）
//     miss_frames  累计「未检测到目标」帧数（饱和）
//     frame_tick   帧末 1 个 clk 的脉冲
//
//   vsync 的边沿约定（重要）：
//     tb_armor_vision 里 vsync 是「宽 101 拍的电平」，不是单拍脉冲；真机上 rd_vsync
//     的形态取决于 ddr3_fifo_ctrl。为了让两种情况都对，这里一律用边沿：
//       - 上升沿 = 帧起点 -> 锁存上一帧统计量、清零重新计数
//       - 下降沿再晚一拍 = frame_tick（此时上游本级流水的结果已稳定）
//     如果直接用 vsync 电平当条件，宽 vsync 会把计数器反复清零，frame_cyc 恒为 0。
//
//   计数饱和：全部到顶即停，避免长时间运行回绕。
//   资源：几个饱和计数器，约 130 LUT / 100 FF，无 BRAM。
//****************************************************************************************//
module vision_stat #(
    parameter CLK_FREQ = 25_000_000        // 像素/显示时钟频率，用于 1 秒窗口
)(
    input                 clk         ,
    input                 rst_n       ,
    input                 vsync       ,   // 帧同步（脉冲或电平都可以）
    input                 de          ,   // 行有效
    input                 mask        ,   // 二值掩码（形态学 + 护栏之后，即送检测那一路）
    input                 bond_valid  ,   // 本帧是否检测到目标

    (* mark_debug = "true" *) output reg [31:0] frame_cyc   ,
    (* mark_debug = "true" *) output reg [15:0] fps         ,
    (* mark_debug = "true" *) output reg [15:0] frame_lines ,
    (* mark_debug = "true" *) output reg [31:0] mask_cnt    ,
    (* mark_debug = "true" *) output reg [15:0] hit_frames  ,
    (* mark_debug = "true" *) output reg [15:0] miss_frames ,
    output reg            frame_tick
);

//reg define
reg  [31:0] cyc_cnt  ;      // 帧内 clk 计数
reg  [15:0] line_cnt ;      // 帧内行计数（de 上升沿）
reg  [31:0] mask_acc ;      // 帧内掩码像素计数
reg         de_d     ;
reg         vsync_d  ;
reg  [31:0] sec_cnt  ;      // 1 秒窗口计数 0 ~ CLK_FREQ-1
reg  [15:0] fps_acc  ;      // 本窗口内数到的帧数

//wire define
wire vsync_rise =  vsync & ~vsync_d;   // 帧起点
wire vsync_fall = ~vsync &  vsync_d;   // 帧结果已稳定

//*****************************************************
//**                    main code
//*****************************************************

//-------------------------------------------------------
// 边沿检测 + 帧末脉冲
//-------------------------------------------------------
always @(posedge clk or negedge rst_n) begin
    if(!rst_n) begin
        de_d      <= 1'b0;
        vsync_d   <= 1'b0;
        frame_tick<= 1'b0;
    end
    else begin
        de_d      <= de;
        vsync_d   <= vsync;
        frame_tick<= vsync_fall;
    end
end

//-------------------------------------------------------
// 帧内计数 + 帧末锁存
//-------------------------------------------------------
always @(posedge clk or negedge rst_n) begin
    if(!rst_n) begin
        cyc_cnt     <= 32'd0;
        line_cnt    <= 16'd0;
        mask_acc    <= 32'd0;
        frame_cyc   <= 32'd0;
        frame_lines <= 16'd0;
        mask_cnt    <= 32'd0;
    end
    else if(vsync_rise) begin
        // 帧起点：先锁存上一帧的统计量，再清零重新开始
        //   必须 +1：cyc_cnt 在两个上升沿之间只数到 (周期-1)，
        //   不加 1 的话 800x480 会报 554399 而不是 554400（实测差一）。
        frame_cyc   <= cyc_cnt + 32'd1;
        frame_lines <= line_cnt;
        mask_cnt    <= mask_acc;
        cyc_cnt     <= 32'd0;
        line_cnt    <= 16'd0;
        mask_acc    <= 32'd0;
    end
    else begin
        cyc_cnt <= cyc_cnt + 1'b1;
        if(de & ~de_d)
            line_cnt <= line_cnt + 1'b1;
        if(de & mask & (mask_acc != 32'hFFFFFFFF))
            mask_acc <= mask_acc + 1'b1;
    end
end

//-------------------------------------------------------
// 命中 / 未命中 帧计数
//   在 frame_tick（vsync 下降沿后一拍）采样，此时上游本帧的结果已稳定
//-------------------------------------------------------
always @(posedge clk or negedge rst_n) begin
    if(!rst_n) begin
        hit_frames  <= 16'd0;
        miss_frames <= 16'd0;
    end
    else if(frame_tick) begin
        if(bond_valid) begin
            if(hit_frames  != 16'hFFFF) hit_frames  <= hit_frames  + 1'b1;
        end
        else begin
            if(miss_frames != 16'hFFFF) miss_frames <= miss_frames + 1'b1;
        end
    end
end

//-------------------------------------------------------
// 帧率：1 秒窗口数 vsync 个数
//   比「CLK_FREQ / frame_cyc」省一个除法器，而且给的是真实平均数
//   （帧周期抖动时比瞬时值更有参考价值）。
//-------------------------------------------------------
always @(posedge clk or negedge rst_n) begin
    if(!rst_n) begin
        sec_cnt <= 32'd0;
        fps_acc <= 16'd0;
        fps     <= 16'd0;
    end
    else if(sec_cnt == CLK_FREQ - 1) begin
        sec_cnt <= 32'd0;
        fps     <= fps_acc;             // 窗口到点：锁存并重新开始
        fps_acc <= 16'd0;
    end
    else begin
        sec_cnt <= sec_cnt + 1'b1;
        if(frame_tick && (fps_acc != 16'hFFFF))
            fps_acc <= fps_acc + 1'b1;
    end
end

endmodule
