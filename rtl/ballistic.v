`timescale 1ns / 1ps
//****************************************************************************************//
// File name:           ballistic
// Descriptions:        距离反推 + 弹道下坠补偿（P11）—— 由本文件顶部的公式自动生成
//
//   注意：本文件由 tools/gen_ballistic_lut.py 生成，不要手改表格；
//         改公式/常数请改那个脚本再重跑（它会重算 256 项表并覆盖这里）。
//
//   一、距离
//       dist_cm = 14135 / w        （f_px=2570px、灯直径 55mm、w = 表观宽度像素）
//   二、弹道下坠（世界->像素）
//       dist_m = dist_cm/100 ;  t = dist_m/v0 ;  drop_m = g*t^2/2
//       px_per_mm = w/55 ;  drop_px = drop_m*1000 * px_per_mm
//       化简后 drop_px = 4454.5 / w   <- w 只剩一次幂，所以两张表都只是 1/w
//   三、弹速可调（免重新综合）
//       drop = (drop_base * (DROP_SCALE+1)) >> 8     <- +1 让 255 正好等于 x1.0
//       DROP_SCALE = round(256*(20/v0)^2) - 1 :  20m/s->255  25m/s->163  30m/s->113  15m/s->454
//   四、最终建议瞄准点（云台直接用这个）
//       fx = 预测灯心 x
//       fy = 预测灯心 y - (w*AIM_H_Q8/256) - drop_px      （单调饱和，不会绕到画面底部）
//       直译：先把几何偏移（打击点在灯上方）算进去，再把下坠补偿抬上去。
//
//   时序：与 blob_track / aim_predict 一致，frame_end = vsync 下降沿延一拍。
//   资源：2 张 256x16 的 ROM（约 8Kb LUTRAM）+ 1 个乘法器，约 120 LUT / 90 FF。
//****************************************************************************************//
module ballistic #(
    parameter AW     = 10,      // 坐标位宽
    parameter WIDTH  = 800,     // 图像宽
    parameter HEIGHT = 480      // 图像高
)(
    input                 clk       ,
    input                 rst_n     ,
    input                 vsync     ,
    input                 en        ,   // DIST_EN（总开关）
    input                 raw_valid ,   // 本帧是否找到团块
    input      [AW:0]     bw        ,   // 团块宽度（bond_w）
    input      [15:0]     aim_h_q8  ,   // 几何偏移系数
    input      [AW-1:0]   pcx       ,   // 预测灯心（aim_predict 的输出）
    input      [AW-1:0]   pcy       ,
    input      [7:0]      drop_scale,   // Q8，255 = 基准弹速 20m/s（x1.0）

    output reg [15:0]     dist_cm   ,   // 距离（cm，饱和）
    output reg [15:0]     drop_px   ,   // 下坠补偿（像素，已按 DROP_SCALE 修正）
    output reg [AW-1:0]   fx        ,   // 最终建议瞄准点
    output reg [AW-1:0]   fy        ,
    output reg            dist_ok       // 距离有效（有目标且宽度在表内）
);

//localparam
localparam [AW:0] W_MIN = 8;   // 宽度下限（低于此距离外推不可信）

//reg define
reg                          vsync_d  ;
reg                          frame_end;
reg  [15:0]                  drop_base;

//wire define
wire vsync_fall = ~vsync & vsync_d;

//-------------------------------------------------------
// 1/w 两张表（只读 ROM，用 LUTRAM；异步读 + 下游寄存器）
//-------------------------------------------------------
wire [7:0] idx = (bw > 255) ? 8'd255 : bw[7:0];

(* ram_style = "distributed" *) reg [15:0] DIST_MEM [0:255];
(* ram_style = "distributed" *) reg [15:0] DROP_MEM [0:255];

initial begin
        DIST_MEM[  0] = 16'd    0;
        DIST_MEM[  1] = 16'd14135;
        DIST_MEM[  2] = 16'd 7068;
        DIST_MEM[  3] = 16'd 4712;
        DIST_MEM[  4] = 16'd 3534;
        DIST_MEM[  5] = 16'd 2827;
        DIST_MEM[  6] = 16'd 2356;
        DIST_MEM[  7] = 16'd 2019;
        DIST_MEM[  8] = 16'd 1767;
        DIST_MEM[  9] = 16'd 1571;
        DIST_MEM[ 10] = 16'd 1414;
        DIST_MEM[ 11] = 16'd 1285;
        DIST_MEM[ 12] = 16'd 1178;
        DIST_MEM[ 13] = 16'd 1087;
        DIST_MEM[ 14] = 16'd 1010;
        DIST_MEM[ 15] = 16'd  942;
        DIST_MEM[ 16] = 16'd  883;
        DIST_MEM[ 17] = 16'd  831;
        DIST_MEM[ 18] = 16'd  785;
        DIST_MEM[ 19] = 16'd  744;
        DIST_MEM[ 20] = 16'd  707;
        DIST_MEM[ 21] = 16'd  673;
        DIST_MEM[ 22] = 16'd  642;
        DIST_MEM[ 23] = 16'd  615;
        DIST_MEM[ 24] = 16'd  589;
        DIST_MEM[ 25] = 16'd  565;
        DIST_MEM[ 26] = 16'd  544;
        DIST_MEM[ 27] = 16'd  524;
        DIST_MEM[ 28] = 16'd  505;
        DIST_MEM[ 29] = 16'd  487;
        DIST_MEM[ 30] = 16'd  471;
        DIST_MEM[ 31] = 16'd  456;
        DIST_MEM[ 32] = 16'd  442;
        DIST_MEM[ 33] = 16'd  428;
        DIST_MEM[ 34] = 16'd  416;
        DIST_MEM[ 35] = 16'd  404;
        DIST_MEM[ 36] = 16'd  393;
        DIST_MEM[ 37] = 16'd  382;
        DIST_MEM[ 38] = 16'd  372;
        DIST_MEM[ 39] = 16'd  362;
        DIST_MEM[ 40] = 16'd  353;
        DIST_MEM[ 41] = 16'd  345;
        DIST_MEM[ 42] = 16'd  337;
        DIST_MEM[ 43] = 16'd  329;
        DIST_MEM[ 44] = 16'd  321;
        DIST_MEM[ 45] = 16'd  314;
        DIST_MEM[ 46] = 16'd  307;
        DIST_MEM[ 47] = 16'd  301;
        DIST_MEM[ 48] = 16'd  294;
        DIST_MEM[ 49] = 16'd  288;
        DIST_MEM[ 50] = 16'd  283;
        DIST_MEM[ 51] = 16'd  277;
        DIST_MEM[ 52] = 16'd  272;
        DIST_MEM[ 53] = 16'd  267;
        DIST_MEM[ 54] = 16'd  262;
        DIST_MEM[ 55] = 16'd  257;
        DIST_MEM[ 56] = 16'd  252;
        DIST_MEM[ 57] = 16'd  248;
        DIST_MEM[ 58] = 16'd  244;
        DIST_MEM[ 59] = 16'd  240;
        DIST_MEM[ 60] = 16'd  236;
        DIST_MEM[ 61] = 16'd  232;
        DIST_MEM[ 62] = 16'd  228;
        DIST_MEM[ 63] = 16'd  224;
        DIST_MEM[ 64] = 16'd  221;
        DIST_MEM[ 65] = 16'd  217;
        DIST_MEM[ 66] = 16'd  214;
        DIST_MEM[ 67] = 16'd  211;
        DIST_MEM[ 68] = 16'd  208;
        DIST_MEM[ 69] = 16'd  205;
        DIST_MEM[ 70] = 16'd  202;
        DIST_MEM[ 71] = 16'd  199;
        DIST_MEM[ 72] = 16'd  196;
        DIST_MEM[ 73] = 16'd  194;
        DIST_MEM[ 74] = 16'd  191;
        DIST_MEM[ 75] = 16'd  188;
        DIST_MEM[ 76] = 16'd  186;
        DIST_MEM[ 77] = 16'd  184;
        DIST_MEM[ 78] = 16'd  181;
        DIST_MEM[ 79] = 16'd  179;
        DIST_MEM[ 80] = 16'd  177;
        DIST_MEM[ 81] = 16'd  175;
        DIST_MEM[ 82] = 16'd  172;
        DIST_MEM[ 83] = 16'd  170;
        DIST_MEM[ 84] = 16'd  168;
        DIST_MEM[ 85] = 16'd  166;
        DIST_MEM[ 86] = 16'd  164;
        DIST_MEM[ 87] = 16'd  162;
        DIST_MEM[ 88] = 16'd  161;
        DIST_MEM[ 89] = 16'd  159;
        DIST_MEM[ 90] = 16'd  157;
        DIST_MEM[ 91] = 16'd  155;
        DIST_MEM[ 92] = 16'd  154;
        DIST_MEM[ 93] = 16'd  152;
        DIST_MEM[ 94] = 16'd  150;
        DIST_MEM[ 95] = 16'd  149;
        DIST_MEM[ 96] = 16'd  147;
        DIST_MEM[ 97] = 16'd  146;
        DIST_MEM[ 98] = 16'd  144;
        DIST_MEM[ 99] = 16'd  143;
        DIST_MEM[100] = 16'd  141;
        DIST_MEM[101] = 16'd  140;
        DIST_MEM[102] = 16'd  139;
        DIST_MEM[103] = 16'd  137;
        DIST_MEM[104] = 16'd  136;
        DIST_MEM[105] = 16'd  135;
        DIST_MEM[106] = 16'd  133;
        DIST_MEM[107] = 16'd  132;
        DIST_MEM[108] = 16'd  131;
        DIST_MEM[109] = 16'd  130;
        DIST_MEM[110] = 16'd  128;
        DIST_MEM[111] = 16'd  127;
        DIST_MEM[112] = 16'd  126;
        DIST_MEM[113] = 16'd  125;
        DIST_MEM[114] = 16'd  124;
        DIST_MEM[115] = 16'd  123;
        DIST_MEM[116] = 16'd  122;
        DIST_MEM[117] = 16'd  121;
        DIST_MEM[118] = 16'd  120;
        DIST_MEM[119] = 16'd  119;
        DIST_MEM[120] = 16'd  118;
        DIST_MEM[121] = 16'd  117;
        DIST_MEM[122] = 16'd  116;
        DIST_MEM[123] = 16'd  115;
        DIST_MEM[124] = 16'd  114;
        DIST_MEM[125] = 16'd  113;
        DIST_MEM[126] = 16'd  112;
        DIST_MEM[127] = 16'd  111;
        DIST_MEM[128] = 16'd  110;
        DIST_MEM[129] = 16'd  110;
        DIST_MEM[130] = 16'd  109;
        DIST_MEM[131] = 16'd  108;
        DIST_MEM[132] = 16'd  107;
        DIST_MEM[133] = 16'd  106;
        DIST_MEM[134] = 16'd  105;
        DIST_MEM[135] = 16'd  105;
        DIST_MEM[136] = 16'd  104;
        DIST_MEM[137] = 16'd  103;
        DIST_MEM[138] = 16'd  102;
        DIST_MEM[139] = 16'd  102;
        DIST_MEM[140] = 16'd  101;
        DIST_MEM[141] = 16'd  100;
        DIST_MEM[142] = 16'd  100;
        DIST_MEM[143] = 16'd   99;
        DIST_MEM[144] = 16'd   98;
        DIST_MEM[145] = 16'd   97;
        DIST_MEM[146] = 16'd   97;
        DIST_MEM[147] = 16'd   96;
        DIST_MEM[148] = 16'd   96;
        DIST_MEM[149] = 16'd   95;
        DIST_MEM[150] = 16'd   94;
        DIST_MEM[151] = 16'd   94;
        DIST_MEM[152] = 16'd   93;
        DIST_MEM[153] = 16'd   92;
        DIST_MEM[154] = 16'd   92;
        DIST_MEM[155] = 16'd   91;
        DIST_MEM[156] = 16'd   91;
        DIST_MEM[157] = 16'd   90;
        DIST_MEM[158] = 16'd   89;
        DIST_MEM[159] = 16'd   89;
        DIST_MEM[160] = 16'd   88;
        DIST_MEM[161] = 16'd   88;
        DIST_MEM[162] = 16'd   87;
        DIST_MEM[163] = 16'd   87;
        DIST_MEM[164] = 16'd   86;
        DIST_MEM[165] = 16'd   86;
        DIST_MEM[166] = 16'd   85;
        DIST_MEM[167] = 16'd   85;
        DIST_MEM[168] = 16'd   84;
        DIST_MEM[169] = 16'd   84;
        DIST_MEM[170] = 16'd   83;
        DIST_MEM[171] = 16'd   83;
        DIST_MEM[172] = 16'd   82;
        DIST_MEM[173] = 16'd   82;
        DIST_MEM[174] = 16'd   81;
        DIST_MEM[175] = 16'd   81;
        DIST_MEM[176] = 16'd   80;
        DIST_MEM[177] = 16'd   80;
        DIST_MEM[178] = 16'd   79;
        DIST_MEM[179] = 16'd   79;
        DIST_MEM[180] = 16'd   79;
        DIST_MEM[181] = 16'd   78;
        DIST_MEM[182] = 16'd   78;
        DIST_MEM[183] = 16'd   77;
        DIST_MEM[184] = 16'd   77;
        DIST_MEM[185] = 16'd   76;
        DIST_MEM[186] = 16'd   76;
        DIST_MEM[187] = 16'd   76;
        DIST_MEM[188] = 16'd   75;
        DIST_MEM[189] = 16'd   75;
        DIST_MEM[190] = 16'd   74;
        DIST_MEM[191] = 16'd   74;
        DIST_MEM[192] = 16'd   74;
        DIST_MEM[193] = 16'd   73;
        DIST_MEM[194] = 16'd   73;
        DIST_MEM[195] = 16'd   72;
        DIST_MEM[196] = 16'd   72;
        DIST_MEM[197] = 16'd   72;
        DIST_MEM[198] = 16'd   71;
        DIST_MEM[199] = 16'd   71;
        DIST_MEM[200] = 16'd   71;
        DIST_MEM[201] = 16'd   70;
        DIST_MEM[202] = 16'd   70;
        DIST_MEM[203] = 16'd   70;
        DIST_MEM[204] = 16'd   69;
        DIST_MEM[205] = 16'd   69;
        DIST_MEM[206] = 16'd   69;
        DIST_MEM[207] = 16'd   68;
        DIST_MEM[208] = 16'd   68;
        DIST_MEM[209] = 16'd   68;
        DIST_MEM[210] = 16'd   67;
        DIST_MEM[211] = 16'd   67;
        DIST_MEM[212] = 16'd   67;
        DIST_MEM[213] = 16'd   66;
        DIST_MEM[214] = 16'd   66;
        DIST_MEM[215] = 16'd   66;
        DIST_MEM[216] = 16'd   65;
        DIST_MEM[217] = 16'd   65;
        DIST_MEM[218] = 16'd   65;
        DIST_MEM[219] = 16'd   65;
        DIST_MEM[220] = 16'd   64;
        DIST_MEM[221] = 16'd   64;
        DIST_MEM[222] = 16'd   64;
        DIST_MEM[223] = 16'd   63;
        DIST_MEM[224] = 16'd   63;
        DIST_MEM[225] = 16'd   63;
        DIST_MEM[226] = 16'd   63;
        DIST_MEM[227] = 16'd   62;
        DIST_MEM[228] = 16'd   62;
        DIST_MEM[229] = 16'd   62;
        DIST_MEM[230] = 16'd   61;
        DIST_MEM[231] = 16'd   61;
        DIST_MEM[232] = 16'd   61;
        DIST_MEM[233] = 16'd   61;
        DIST_MEM[234] = 16'd   60;
        DIST_MEM[235] = 16'd   60;
        DIST_MEM[236] = 16'd   60;
        DIST_MEM[237] = 16'd   60;
        DIST_MEM[238] = 16'd   59;
        DIST_MEM[239] = 16'd   59;
        DIST_MEM[240] = 16'd   59;
        DIST_MEM[241] = 16'd   59;
        DIST_MEM[242] = 16'd   58;
        DIST_MEM[243] = 16'd   58;
        DIST_MEM[244] = 16'd   58;
        DIST_MEM[245] = 16'd   58;
        DIST_MEM[246] = 16'd   57;
        DIST_MEM[247] = 16'd   57;
        DIST_MEM[248] = 16'd   57;
        DIST_MEM[249] = 16'd   57;
        DIST_MEM[250] = 16'd   57;
        DIST_MEM[251] = 16'd   56;
        DIST_MEM[252] = 16'd   56;
        DIST_MEM[253] = 16'd   56;
        DIST_MEM[254] = 16'd   56;
        DIST_MEM[255] = 16'd   55;
end

initial begin
        DROP_MEM[  0] = 16'd    0;
        DROP_MEM[  1] = 16'd 4455;
        DROP_MEM[  2] = 16'd 2227;
        DROP_MEM[  3] = 16'd 1485;
        DROP_MEM[  4] = 16'd 1114;
        DROP_MEM[  5] = 16'd  891;
        DROP_MEM[  6] = 16'd  742;
        DROP_MEM[  7] = 16'd  636;
        DROP_MEM[  8] = 16'd  557;
        DROP_MEM[  9] = 16'd  495;
        DROP_MEM[ 10] = 16'd  445;
        DROP_MEM[ 11] = 16'd  405;
        DROP_MEM[ 12] = 16'd  371;
        DROP_MEM[ 13] = 16'd  343;
        DROP_MEM[ 14] = 16'd  318;
        DROP_MEM[ 15] = 16'd  297;
        DROP_MEM[ 16] = 16'd  278;
        DROP_MEM[ 17] = 16'd  262;
        DROP_MEM[ 18] = 16'd  247;
        DROP_MEM[ 19] = 16'd  234;
        DROP_MEM[ 20] = 16'd  223;
        DROP_MEM[ 21] = 16'd  212;
        DROP_MEM[ 22] = 16'd  202;
        DROP_MEM[ 23] = 16'd  194;
        DROP_MEM[ 24] = 16'd  186;
        DROP_MEM[ 25] = 16'd  178;
        DROP_MEM[ 26] = 16'd  171;
        DROP_MEM[ 27] = 16'd  165;
        DROP_MEM[ 28] = 16'd  159;
        DROP_MEM[ 29] = 16'd  154;
        DROP_MEM[ 30] = 16'd  148;
        DROP_MEM[ 31] = 16'd  144;
        DROP_MEM[ 32] = 16'd  139;
        DROP_MEM[ 33] = 16'd  135;
        DROP_MEM[ 34] = 16'd  131;
        DROP_MEM[ 35] = 16'd  127;
        DROP_MEM[ 36] = 16'd  124;
        DROP_MEM[ 37] = 16'd  120;
        DROP_MEM[ 38] = 16'd  117;
        DROP_MEM[ 39] = 16'd  114;
        DROP_MEM[ 40] = 16'd  111;
        DROP_MEM[ 41] = 16'd  109;
        DROP_MEM[ 42] = 16'd  106;
        DROP_MEM[ 43] = 16'd  104;
        DROP_MEM[ 44] = 16'd  101;
        DROP_MEM[ 45] = 16'd   99;
        DROP_MEM[ 46] = 16'd   97;
        DROP_MEM[ 47] = 16'd   95;
        DROP_MEM[ 48] = 16'd   93;
        DROP_MEM[ 49] = 16'd   91;
        DROP_MEM[ 50] = 16'd   89;
        DROP_MEM[ 51] = 16'd   87;
        DROP_MEM[ 52] = 16'd   86;
        DROP_MEM[ 53] = 16'd   84;
        DROP_MEM[ 54] = 16'd   82;
        DROP_MEM[ 55] = 16'd   81;
        DROP_MEM[ 56] = 16'd   80;
        DROP_MEM[ 57] = 16'd   78;
        DROP_MEM[ 58] = 16'd   77;
        DROP_MEM[ 59] = 16'd   76;
        DROP_MEM[ 60] = 16'd   74;
        DROP_MEM[ 61] = 16'd   73;
        DROP_MEM[ 62] = 16'd   72;
        DROP_MEM[ 63] = 16'd   71;
        DROP_MEM[ 64] = 16'd   70;
        DROP_MEM[ 65] = 16'd   69;
        DROP_MEM[ 66] = 16'd   67;
        DROP_MEM[ 67] = 16'd   66;
        DROP_MEM[ 68] = 16'd   66;
        DROP_MEM[ 69] = 16'd   65;
        DROP_MEM[ 70] = 16'd   64;
        DROP_MEM[ 71] = 16'd   63;
        DROP_MEM[ 72] = 16'd   62;
        DROP_MEM[ 73] = 16'd   61;
        DROP_MEM[ 74] = 16'd   60;
        DROP_MEM[ 75] = 16'd   59;
        DROP_MEM[ 76] = 16'd   59;
        DROP_MEM[ 77] = 16'd   58;
        DROP_MEM[ 78] = 16'd   57;
        DROP_MEM[ 79] = 16'd   56;
        DROP_MEM[ 80] = 16'd   56;
        DROP_MEM[ 81] = 16'd   55;
        DROP_MEM[ 82] = 16'd   54;
        DROP_MEM[ 83] = 16'd   54;
        DROP_MEM[ 84] = 16'd   53;
        DROP_MEM[ 85] = 16'd   52;
        DROP_MEM[ 86] = 16'd   52;
        DROP_MEM[ 87] = 16'd   51;
        DROP_MEM[ 88] = 16'd   51;
        DROP_MEM[ 89] = 16'd   50;
        DROP_MEM[ 90] = 16'd   49;
        DROP_MEM[ 91] = 16'd   49;
        DROP_MEM[ 92] = 16'd   48;
        DROP_MEM[ 93] = 16'd   48;
        DROP_MEM[ 94] = 16'd   47;
        DROP_MEM[ 95] = 16'd   47;
        DROP_MEM[ 96] = 16'd   46;
        DROP_MEM[ 97] = 16'd   46;
        DROP_MEM[ 98] = 16'd   45;
        DROP_MEM[ 99] = 16'd   45;
        DROP_MEM[100] = 16'd   45;
        DROP_MEM[101] = 16'd   44;
        DROP_MEM[102] = 16'd   44;
        DROP_MEM[103] = 16'd   43;
        DROP_MEM[104] = 16'd   43;
        DROP_MEM[105] = 16'd   42;
        DROP_MEM[106] = 16'd   42;
        DROP_MEM[107] = 16'd   42;
        DROP_MEM[108] = 16'd   41;
        DROP_MEM[109] = 16'd   41;
        DROP_MEM[110] = 16'd   40;
        DROP_MEM[111] = 16'd   40;
        DROP_MEM[112] = 16'd   40;
        DROP_MEM[113] = 16'd   39;
        DROP_MEM[114] = 16'd   39;
        DROP_MEM[115] = 16'd   39;
        DROP_MEM[116] = 16'd   38;
        DROP_MEM[117] = 16'd   38;
        DROP_MEM[118] = 16'd   38;
        DROP_MEM[119] = 16'd   37;
        DROP_MEM[120] = 16'd   37;
        DROP_MEM[121] = 16'd   37;
        DROP_MEM[122] = 16'd   37;
        DROP_MEM[123] = 16'd   36;
        DROP_MEM[124] = 16'd   36;
        DROP_MEM[125] = 16'd   36;
        DROP_MEM[126] = 16'd   35;
        DROP_MEM[127] = 16'd   35;
        DROP_MEM[128] = 16'd   35;
        DROP_MEM[129] = 16'd   35;
        DROP_MEM[130] = 16'd   34;
        DROP_MEM[131] = 16'd   34;
        DROP_MEM[132] = 16'd   34;
        DROP_MEM[133] = 16'd   33;
        DROP_MEM[134] = 16'd   33;
        DROP_MEM[135] = 16'd   33;
        DROP_MEM[136] = 16'd   33;
        DROP_MEM[137] = 16'd   33;
        DROP_MEM[138] = 16'd   32;
        DROP_MEM[139] = 16'd   32;
        DROP_MEM[140] = 16'd   32;
        DROP_MEM[141] = 16'd   32;
        DROP_MEM[142] = 16'd   31;
        DROP_MEM[143] = 16'd   31;
        DROP_MEM[144] = 16'd   31;
        DROP_MEM[145] = 16'd   31;
        DROP_MEM[146] = 16'd   31;
        DROP_MEM[147] = 16'd   30;
        DROP_MEM[148] = 16'd   30;
        DROP_MEM[149] = 16'd   30;
        DROP_MEM[150] = 16'd   30;
        DROP_MEM[151] = 16'd   30;
        DROP_MEM[152] = 16'd   29;
        DROP_MEM[153] = 16'd   29;
        DROP_MEM[154] = 16'd   29;
        DROP_MEM[155] = 16'd   29;
        DROP_MEM[156] = 16'd   29;
        DROP_MEM[157] = 16'd   28;
        DROP_MEM[158] = 16'd   28;
        DROP_MEM[159] = 16'd   28;
        DROP_MEM[160] = 16'd   28;
        DROP_MEM[161] = 16'd   28;
        DROP_MEM[162] = 16'd   27;
        DROP_MEM[163] = 16'd   27;
        DROP_MEM[164] = 16'd   27;
        DROP_MEM[165] = 16'd   27;
        DROP_MEM[166] = 16'd   27;
        DROP_MEM[167] = 16'd   27;
        DROP_MEM[168] = 16'd   27;
        DROP_MEM[169] = 16'd   26;
        DROP_MEM[170] = 16'd   26;
        DROP_MEM[171] = 16'd   26;
        DROP_MEM[172] = 16'd   26;
        DROP_MEM[173] = 16'd   26;
        DROP_MEM[174] = 16'd   26;
        DROP_MEM[175] = 16'd   25;
        DROP_MEM[176] = 16'd   25;
        DROP_MEM[177] = 16'd   25;
        DROP_MEM[178] = 16'd   25;
        DROP_MEM[179] = 16'd   25;
        DROP_MEM[180] = 16'd   25;
        DROP_MEM[181] = 16'd   25;
        DROP_MEM[182] = 16'd   24;
        DROP_MEM[183] = 16'd   24;
        DROP_MEM[184] = 16'd   24;
        DROP_MEM[185] = 16'd   24;
        DROP_MEM[186] = 16'd   24;
        DROP_MEM[187] = 16'd   24;
        DROP_MEM[188] = 16'd   24;
        DROP_MEM[189] = 16'd   24;
        DROP_MEM[190] = 16'd   23;
        DROP_MEM[191] = 16'd   23;
        DROP_MEM[192] = 16'd   23;
        DROP_MEM[193] = 16'd   23;
        DROP_MEM[194] = 16'd   23;
        DROP_MEM[195] = 16'd   23;
        DROP_MEM[196] = 16'd   23;
        DROP_MEM[197] = 16'd   23;
        DROP_MEM[198] = 16'd   22;
        DROP_MEM[199] = 16'd   22;
        DROP_MEM[200] = 16'd   22;
        DROP_MEM[201] = 16'd   22;
        DROP_MEM[202] = 16'd   22;
        DROP_MEM[203] = 16'd   22;
        DROP_MEM[204] = 16'd   22;
        DROP_MEM[205] = 16'd   22;
        DROP_MEM[206] = 16'd   22;
        DROP_MEM[207] = 16'd   22;
        DROP_MEM[208] = 16'd   21;
        DROP_MEM[209] = 16'd   21;
        DROP_MEM[210] = 16'd   21;
        DROP_MEM[211] = 16'd   21;
        DROP_MEM[212] = 16'd   21;
        DROP_MEM[213] = 16'd   21;
        DROP_MEM[214] = 16'd   21;
        DROP_MEM[215] = 16'd   21;
        DROP_MEM[216] = 16'd   21;
        DROP_MEM[217] = 16'd   21;
        DROP_MEM[218] = 16'd   20;
        DROP_MEM[219] = 16'd   20;
        DROP_MEM[220] = 16'd   20;
        DROP_MEM[221] = 16'd   20;
        DROP_MEM[222] = 16'd   20;
        DROP_MEM[223] = 16'd   20;
        DROP_MEM[224] = 16'd   20;
        DROP_MEM[225] = 16'd   20;
        DROP_MEM[226] = 16'd   20;
        DROP_MEM[227] = 16'd   20;
        DROP_MEM[228] = 16'd   20;
        DROP_MEM[229] = 16'd   19;
        DROP_MEM[230] = 16'd   19;
        DROP_MEM[231] = 16'd   19;
        DROP_MEM[232] = 16'd   19;
        DROP_MEM[233] = 16'd   19;
        DROP_MEM[234] = 16'd   19;
        DROP_MEM[235] = 16'd   19;
        DROP_MEM[236] = 16'd   19;
        DROP_MEM[237] = 16'd   19;
        DROP_MEM[238] = 16'd   19;
        DROP_MEM[239] = 16'd   19;
        DROP_MEM[240] = 16'd   19;
        DROP_MEM[241] = 16'd   18;
        DROP_MEM[242] = 16'd   18;
        DROP_MEM[243] = 16'd   18;
        DROP_MEM[244] = 16'd   18;
        DROP_MEM[245] = 16'd   18;
        DROP_MEM[246] = 16'd   18;
        DROP_MEM[247] = 16'd   18;
        DROP_MEM[248] = 16'd   18;
        DROP_MEM[249] = 16'd   18;
        DROP_MEM[250] = 16'd   18;
        DROP_MEM[251] = 16'd   18;
        DROP_MEM[252] = 16'd   18;
        DROP_MEM[253] = 16'd   18;
        DROP_MEM[254] = 16'd   18;
        DROP_MEM[255] = 16'd   17;
end

wire [15:0] dist_rom = DIST_MEM[idx];
wire [15:0] drop_rom = DROP_MEM[idx];

//-------------------------------------------------------
// 几何偏移（与 blob_track / aim_predict 同一公式）
//-------------------------------------------------------
wire [2*AW+8:0] up_full = bw * aim_h_q8;
wire [AW+8:0]   up_t    = up_full >> 8;

//  下坠按弹速缩放：drop = (drop_base * (DROP_SCALE+1)) >> 8
wire [8:0]  sc       = {1'b0, drop_scale} + 9'd1;      // 255 -> 256 = x1.0
wire [24:0] drop_sc  = drop_rom * sc;
wire [15:0] drop_eff = en ? drop_sc[23:8] : 16'd0;

//  单调饱和：fy = pcy - up - drop，减不够就取 0（绝不绕到画面底部）
wire [AW+9:0] sub_tot = {1'b0, {7{1'b0}}, up_t} + {4'b0, drop_eff};
wire [AW+9:0] py_l    = {10'd0, pcy};
wire [AW+9:0] fy_c    = (py_l >= sub_tot) ? (py_l - sub_tot) : {(AW+10){1'b0}};

//-------------------------------------------------------
// 帧边界：延一拍（读到刚结束那一帧的结果）
//-------------------------------------------------------
always @(posedge clk or negedge rst_n) begin
    if(!rst_n) begin
        vsync_d   <= 1'b0;
        frame_end <= 1'b0;
    end
    else begin
        vsync_d   <= vsync;
        frame_end <= vsync_fall;
    end
end

always @(posedge clk or negedge rst_n) begin
    if(!rst_n) begin
        dist_cm   <= 16'd0;
        drop_px   <= 16'd0;
        drop_base <= 16'd0;
        fx        <= {AW{1'b0}};
        fy        <= {AW{1'b0}};
        dist_ok   <= 1'b0;
    end
    else if(frame_end) begin
        if(en && raw_valid && (bw >= W_MIN)) begin
            dist_cm   <= dist_rom;
            drop_px   <= drop_eff;
            drop_base <= drop_rom;
            dist_ok   <= 1'b1;
        end
        else begin
            dist_cm   <= 16'd0;
            drop_px   <= 16'd0;
            drop_base <= 16'd0;
            dist_ok   <= 1'b0;
        end
        fx <= pcx;
        fy <= fy_c[AW-1:0];
    end
end

endmodule
