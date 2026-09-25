`timescale 1ns / 1ps
//****************************************************************************************//
// File name:           temporal_acc
// Descriptions:        多帧时间累积（P12）—— 提升远小绿灯的灵敏度与稳定度
//
//   为什么要：
//     远距离的绿灯只有几十个像素，某一帧因为反光、噪声、曝光抖动，面积会掉到
//     min_area_lo 之下，或形状判据不过 -> blob 断链、目标消失一两帧，
//     后面的预测与跟踪就跟着断掉。
//     把「连续几帧都亮」的位置累积起来，就能把真目标粘住。
//
//   为什么不用「直接并集（OR）」：
//     并集会把单帧噪点也粘住（K 帧内任何噪点都留下），反而造出假目标。
//     这里用 2 bit 饱和计数器：
//        mask=1 -> acc+1（饱和到 3）
//        mask=0 -> acc-1（饱和到 0）
//        mask_out = (acc >= thr)       thr 默认为 2
//     -> 单帧噪点只有 1，下一帧就掉回 0，能被拒绝；
//        真目标连续两帧就粘住，中间丢一帧也还在；
//        2~3 帧都不亮则自动消失，不留残影。
//
//   时序（很重要）：
//     本模块输出延时 2 拍（BRAM 同步读 1 拍 + 判据寄存 1 拍），所以
//     x/y/de 也一并延 2 拍，保证下游 blob_track 拿到的坐标与 mask 属于同一像素，
//     否则目标坐标会整体偏移 2 个像素。
//     en=0、强制清零、自动清空期间走直通路径（零延迟），
//     所以「默认关闭」时行为与不加本模块完全一致。
//
//   资源：WIDTH*HEIGHT*2 bit 的块 RAM（800x480 -> 768Kb -> 约 21~22 个 RAMB36），
//         是视觉管线里唯一用 BRAM 的地方（其余全部推给 LUTRAM）。
//         若 BRAM 不够：把 acc_mem 位宽改成 1 bit（只用 acc | mask），
//         代价是单帧噪点也会被留一帧，那时得靠 min_area_lo 再兜一层。
//
//   复位后自动清空一次（对 RAM 写 0）：800x480 共 384000 拍，
//   在 50MHz 下约 7.7ms，一帧之内完成，不占用别人的 BRAM 端口。
//****************************************************************************************//
module temporal_acc #(
    parameter WIDTH = 800,      // 图像宽度
    parameter HEIGHT= 480,      // 图像高度
    parameter AW    = 10        // 坐标位宽
)(
    input                clk     ,
    input                rst_n   ,
    input                de      ,   // 行有效（逐像素）
    input      [AW-1:0]  x       ,
    input      [AW-1:0]  y       ,   // 行号 1 基，与 armor_vision 内部一致
    input                mask_in ,
    input                en      ,   // 0 = 关闭（直通）
    input      [1:0]     thr     ,   // 门限 0~3
    input                clr     ,   // 1 = 软件强制清空

    output     [AW-1:0]  x_o     ,   // 与 mask_o 同拍
    output     [AW-1:0]  y_o     ,
    output               de_o    ,
    output               mask_o
);

//localparam
localparam DEPTH = WIDTH * HEIGHT;
localparam CLR_LAST = DEPTH - 1;

//reg define
(* ram_style = "block" *) reg [1:0] acc_mem [0:DEPTH-1];

reg  [20:0] adr_w   ;
reg  [1:0]  acc_q   ;
reg         mask_d1 ;
reg         de_d    ;
reg         clr_run ;
reg  [20:0] clr_adr ;
reg  [AW-1:0] x_r1, x_r2;
reg  [AW-1:0] y_r1, y_r2;
reg         de_r1, de_r2;
reg         mask_r  ;

//wire define
wire [AW-1:0] ym1 = y - 1'b1;
//  行首地址 = (y-1)*WIDTH；WIDTH=800 = 512+256+32 -> 用移位相加代替乘法
//  这里必须用 WIDTH（而不是写死 800）：否则用小 WIDTH 做单元测试时地址会全部越界
//  WIDTH 是常量（800 = 512+256+32），综合会化成移位相加，不会真的放乘法器
wire [20:0] row_base = {{(21-AW){1'b0}}, ym1} * WIDTH;
wire [20:0] adr_nx   = row_base + {{(21-AW){1'b0}}, x};

wire [1:0] acc_up = (acc_q == 2'd3) ? 2'd3 : (acc_q + 2'd1);
wire [1:0] acc_dn = (acc_q == 2'd0) ? 2'd0 : (acc_q - 2'd1);
wire [1:0] acc_nx = mask_d1 ? acc_up : acc_dn;

wire byp = (~en) | clr | clr_run;          // 关闭/软件清零/自动清空 -> 直通

wire        we    = clr_run ? 1'b1 : (de_d & ~clr & en);
//  写地址必须用 adr_w（延 1 拍）：它和 we(=de_d)、wdata(=acc_nx) 同一拍，
//  而 acc_q 是在这个地址读出的下一拍到 —— 三者对齐才不会把新值写到上一个像素
wire [20:0] waddr = clr_run ? clr_adr : adr_w;
wire [1:0]  wdata = clr_run ? 2'd0 : acc_nx;

//*****************************************************
//**                    main code
//*****************************************************

//-------------------------------------------------------
// 单写口 BRAM：清空与正常累加共用，用 mux 选
//-------------------------------------------------------
always @(posedge clk) begin
    if(we) acc_mem[waddr] <= wdata;
end

//-------------------------------------------------------
// 读地址 + 2 拍打拍
//-------------------------------------------------------
always @(posedge clk or negedge rst_n) begin
    if(!rst_n) begin
        adr_w   <= 21'd0;
        acc_q   <= 2'd0;
        mask_d1 <= 1'b0;
        de_d    <= 1'b0;
    end
    else begin
        adr_w   <= adr_nx;              // 写地址：与 we/wdata 同为「延 1 拍」
        //  读也使能判断：关闭时完全不碰这块大 RAM（xsim 的数组访问很贵，
        //  每帧 384000 次会把仿真时间翻倍）；开启时行为不变。
        if(de && en) acc_q <= acc_mem[adr_nx];   // BRAM 同步读：下一拍出数
        mask_d1 <= mask_in;
        de_d    <= de;
    end
end

always @(posedge clk or negedge rst_n) begin
    if(!rst_n) begin
        x_r1 <= {AW{1'b0}}; x_r2 <= {AW{1'b0}};
        y_r1 <= {AW{1'b0}}; y_r2 <= {AW{1'b0}};
        de_r1<= 1'b0;       de_r2<= 1'b0;
        mask_r<= 1'b0;
    end
    else begin
        x_r1 <= x;      x_r2 <= x_r1;      // 和 mask_r 一样延 2 拍
        y_r1 <= y;      y_r2 <= y_r1;
        de_r1<= de;     de_r2<= de_r1;
        mask_r <= (acc_nx >= thr);
    end
end

//-------------------------------------------------------
// 复位后自动清空 BRAM（开机时走一圈，之后不再动）
//-------------------------------------------------------
always @(posedge clk or negedge rst_n) begin
    if(!rst_n) begin
        clr_run <= 1'b1;
        clr_adr <= 21'd0;
    end
    else if(clr) begin                  // 软件强制清零：重新走一圈（走完自动恢复累积）
        clr_run <= 1'b1;
        clr_adr <= 21'd0;
    end
    else if(clr_run) begin
        if(clr_adr == CLR_LAST) clr_run <= 1'b0;
        else                    clr_adr <= clr_adr + 21'd1;
    end
end

//-------------------------------------------------------
// 直通时零延迟；正常时把 x/y/de 也延 2 拍对齐
//-------------------------------------------------------
assign x_o    = byp ? x      : x_r2;
assign y_o    = byp ? y      : y_r2;
assign de_o   = byp ? de     : de_r2;
assign mask_o = byp ? mask_in: mask_r;

endmodule
