`timescale 1ns / 1ps
//****************************************************************************************//
// File name:           osd_text
// Descriptions:        OSD ��ֵ���� + ֱ��ͼ����ͼ��P8��
//
//   ����������� + �ײ�һ��ֱ��ͼ�����δӴ˲��ÿ��£�
//     F0 fps      : ֡�ʣ���֡һ�ۿ�������
//     F1 th_gr    : ��ǰ G-R ��ֵ������Ӧʱ�ܿ������Լ���ô�䣩
//     F2 area     : �ſ������Ҳ�ǲ���ԭ�ϣ�
//     F3 fill_q8  : ����� x256��Բ������ֵԼ 201 ���� ������֪��Բ��Բ��
//
//   Ϊʲô F3 ���ž��룺������ƾ���Ҫ�����ţ��������/��ͷû�궨֮ǰ����ֵû���塣
//   Ҫ�������� F2 ���������λ�����㣬������ sqrt ����ѵġ�
//
//   �ֺ� 3x5 ���󡢷Ŵ� 2 �� -> 6x10 ����/�֡��� 800x480 ��������������� ROM ��С��
//
//   ����Ҫ��ʮ����λ�ֽ��õ���**���� double-dabble**�����ǳ���������
//     һ��ʼд�� `v/32'd100000 % 10` ��������ϳ��������
//       (a) 6 �� 32bit ��������Լ 1000+ LUT
//       (b) ������ÿ��ʱ�Ӷ�Ҫ����һ�� -> xsim ���������ܲ�����ʵ��ֱ�ӿ��� phase 2��
//     double-dabble ֻҪ��λ + ÿλ >=5 �� 3�������ӷ����͹���
//     һ֡�ֽ� 4 ������ 80 �ģ�һ֡ 55 ���ģ���ȫ����ν��
//
//   ��Դ��Լ 300 LUT + Լ 120 FF��0 BRAM��0 DSP��0 ��������
//****************************************************************************************//
module osd_text #(
    parameter [1:0]  SCALE    = 2'd1,      // �Ŵ���-1��1 = 2 ����
    parameter [7:0]  BAR_SHIFT= 8'd6,      // ֱ��ͼ�߶����ţ����� >> SHIFT��
    parameter [9:0]  BAR_MAXH = 10'd90     // ����ͼ�������
)(
    input              clk        ,
    input              rst_n      ,
    input              vsync      ,
    input      [9:0]   x          ,
    input      [9:0]   y          ,
    input              en         ,   // OSD_EN
    input      [15:0]  fps        ,
    input      [7:0]   th_gr      ,
    input      [31:0]  area       ,
    input      [7:0]   fill_in    ,
    //  ֱ��ͼ�첽����
    output     [7:0]   hraddr     ,
    input      [19:0]  hrdata_gr  ,

    output reg         osd_on     ,
    output reg [15:0]  osd_color
);

//localparam
localparam [9:0] F0_Y = 10'd8 ;      // fps
localparam [9:0] F1_Y = 10'd24;      // th_gr
localparam [9:0] F2_Y = 10'd40;      // area
localparam [9:0] F3_Y = 10'd56;      // fill_q8
localparam [9:0] FX   = 10'd8 ;
localparam [9:0] BAR_Y = 10'd470;    // ����ͼ����
localparam [15:0] COL_TEXT = 16'hFFE0;   // ��
localparam [15:0] COL_BAR  = 16'h07FF;   // ��

//reg define
reg  [3:0] dg0 [0:5];      // fps   ��� 6 λ
reg  [3:0] dg1 [0:5];
reg  [3:0] dg2 [0:5];
reg  [3:0] dg3 [0:5];
reg  [2:0] nd0, nd1, nd2, nd3;   // ��Чλ��
reg        vsync_d;

//  double-dabble ����ת��
localparam CV_IDLE = 2'd0, CV_LOOP = 2'd1, CV_SAVE = 2'd2;
reg  [1:0]  cv_state;
reg  [1:0]  cv_sel  ;      // 0=fps 1=th_gr 2=area 3=fill
reg  [4:0]  cv_it   ;
reg  [19:0] cv_bin  ;
reg  [23:0] cv_bcd  ;      // 6 λ BCD
reg  [23:0] b0_bcd, b1_bcd, b2_bcd, b3_bcd;
reg         conv_done;     // �ĸ�����ת�� -> ��һ��ˢ�����ּĴ���

//wire define
wire vsync_rise = vsync & ~vsync_d;

//*****************************************************
//**                    main code
//*****************************************************

always @(posedge clk or negedge rst_n) begin
    if(!rst_n) vsync_d <= 1'b0;
    else       vsync_d <= vsync;
end

//-------------------------------------------------------
// ��ת����ֵ������ 20bit ���ڣ�
//   fps �� 16bit����� 65535��������չ����
//-------------------------------------------------------
wire [19:0] v_fps  = {4'd0, fps};
wire [19:0] v_th   = {12'd0, th_gr};
wire [19:0] v_area = (area > 32'd999999) ? 20'd999999 : area[19:0];
wire [19:0] v_fill = {12'd0, fill_in};

wire [19:0] cv_src = (cv_sel == 2'd0) ? v_fps  :
                     (cv_sel == 2'd1) ? v_th   :
                     (cv_sel == 2'd2) ? v_area : v_fill;

//-------------------------------------------------------
// double-dabble��ÿλ >=5 �ͼ� 3����ϣ�ֻ�����ӷ�����
//-------------------------------------------------------
integer bi;
reg [23:0] bcd_fix;

always @(*) begin
    bcd_fix = cv_bcd;
    for(bi = 0; bi < 6; bi = bi + 1)
        if(cv_bcd[4*bi +: 4] >= 4'd5)
            bcd_fix[4*bi +: 4] = cv_bcd[4*bi +: 4] + 4'd3;
end

//-------------------------------------------------------
// ֡ĩ����ת�� 4 ������ÿ�� 20 �ģ��� 80 �ģ�
//-------------------------------------------------------
always @(posedge clk or negedge rst_n) begin
    if(!rst_n) begin
        cv_state  <= CV_IDLE;
        cv_sel    <= 2'd0;
        cv_it     <= 5'd0;
        cv_bin    <= 20'd0;
        cv_bcd    <= 24'd0;
        b0_bcd    <= 24'd0; b1_bcd <= 24'd0;
        b2_bcd    <= 24'd0; b3_bcd <= 24'd0;
        conv_done <= 1'b0;
    end
    else begin
        //  conv_done = 「本拍刚好把第 4 个数存完」的单拍脉冲。
        //  只允许这一个 always 块驱动它 —— 另一个块只读不写，
        //  否则会成为多驱动网络，Vivado 报 [DRC MDRV-1]，Opt_design 跑不起来。
        conv_done <= (cv_state == CV_SAVE) && (cv_sel == 2'd3);

        case(cv_state)
            CV_IDLE: begin
                if(vsync_rise) begin
                    cv_sel   <= 2'd0;
                    cv_bin   <= v_fps;
                    cv_bcd   <= 24'd0;
                    cv_it    <= 5'd0;
                    cv_state <= CV_LOOP;
                end
            end

            CV_LOOP: begin
                cv_bcd <= {bcd_fix[22:0], cv_bin[19]};
                cv_bin <= {cv_bin[18:0], 1'b0};
                cv_it  <= cv_it + 5'd1;
                if(cv_it == 5'd19) cv_state <= CV_SAVE;
            end

            default: begin   // CV_SAVE
                case(cv_sel)
                    2'd0:    b0_bcd <= {bcd_fix[22:0], cv_bin[19]};
                    2'd1:    b1_bcd <= {bcd_fix[22:0], cv_bin[19]};
                    2'd2:    b2_bcd <= {bcd_fix[22:0], cv_bin[19]};
                    default: b3_bcd <= {bcd_fix[22:0], cv_bin[19]};
                endcase

                if(cv_sel == 2'd3) begin
                    cv_state <= CV_IDLE;
                end
                else begin
                    cv_sel   <= cv_sel + 2'd1;
                    cv_bcd   <= 24'd0;
                    cv_bin   <= (cv_sel == 2'd0) ? v_th   :
                                (cv_sel == 2'd1) ? v_area : v_fill;
                    cv_it    <= 5'd0;
                    cv_state <= CV_LOOP;
                end
            end
        endcase
    end
end

//-------------------------------------------------------
// BCD -> ��λ���֣�������Чλ�����루��λ����
//-------------------------------------------------------
function [2:0] ndig;
    input [23:0] b;     // 6 λ BCD
    begin
        if(b[23:20] != 4'd0)      ndig = 3'd6;
        else if(b[19:16] != 4'd0) ndig = 3'd5;
        else if(b[15:12] != 4'd0) ndig = 3'd4;
        else if(b[11:8]  != 4'd0) ndig = 3'd3;
        else if(b[7:4]   != 4'd0) ndig = 3'd2;
        else                      ndig = 3'd1;
    end
endfunction

always @(posedge clk or negedge rst_n) begin
    if(!rst_n) begin
        nd0<=3'd3; nd1<=3'd3; nd2<=3'd6; nd3<=3'd3;
        dg0[0]<=4'd0; dg0[1]<=4'd0; dg0[2]<=4'd0; dg0[3]<=4'd0; dg0[4]<=4'd0; dg0[5]<=4'd0;
        dg1[0]<=4'd0; dg1[1]<=4'd0; dg1[2]<=4'd0; dg1[3]<=4'd0; dg1[4]<=4'd0; dg1[5]<=4'd0;
        dg2[0]<=4'd0; dg2[1]<=4'd0; dg2[2]<=4'd0; dg2[3]<=4'd0; dg2[4]<=4'd0; dg2[5]<=4'd0;
        dg3[0]<=4'd0; dg3[1]<=4'd0; dg3[2]<=4'd0; dg3[3]<=4'd0; dg3[4]<=4'd0; dg3[5]<=4'd0;
    end
    else if(conv_done) begin      // 只读 conv_done，不写 -> 保持单驱动
        //  �ĸ�����ת���ˣ�ˢ��һ�����ּĴ�����ÿֻ֡��һ�Σ�
        nd0 <= ndig(b0_bcd);
        nd1 <= ndig(b1_bcd);
        nd2 <= ndig(b2_bcd);
        nd3 <= ndig(b3_bcd);

        dg0[0]<=b0_bcd[3:0];   dg0[1]<=b0_bcd[7:4];   dg0[2]<=b0_bcd[11:8];
        dg0[3]<=b0_bcd[15:12]; dg0[4]<=b0_bcd[19:16]; dg0[5]<=b0_bcd[23:20];

        dg1[0]<=b1_bcd[3:0];   dg1[1]<=b1_bcd[7:4];   dg1[2]<=b1_bcd[11:8];
        dg1[3]<=b1_bcd[15:12]; dg1[4]<=b1_bcd[19:16]; dg1[5]<=b1_bcd[23:20];

        dg2[0]<=b2_bcd[3:0];   dg2[1]<=b2_bcd[7:4];   dg2[2]<=b2_bcd[11:8];
        dg2[3]<=b2_bcd[15:12]; dg2[4]<=b2_bcd[19:16]; dg2[5]<=b2_bcd[23:20];

        dg3[0]<=b3_bcd[3:0];   dg3[1]<=b3_bcd[7:4];   dg3[2]<=b3_bcd[11:8];
        dg3[3]<=b3_bcd[15:12]; dg3[4]<=b3_bcd[19:16]; dg3[5]<=b3_bcd[23:20];
    end
end

//-------------------------------------------------------
// �ֺţ�3x5 ����ÿ�� 3 bit���� 5 �У�bit2 = ����
//-------------------------------------------------------
function [14:0] glyph;
    input [3:0] d;
    begin
        case(d)
            4'd0: glyph = 15'b111_101_101_101_111;
            4'd1: glyph = 15'b010_110_010_010_111;
            4'd2: glyph = 15'b111_001_111_100_111;
            4'd3: glyph = 15'b111_001_111_001_111;
            4'd4: glyph = 15'b101_101_111_001_001;
            4'd5: glyph = 15'b111_100_111_001_111;
            4'd6: glyph = 15'b111_100_111_101_111;
            4'd7: glyph = 15'b111_001_001_001_001;
            4'd8: glyph = 15'b111_101_111_101_111;
            4'd9: glyph = 15'b111_101_111_001_111;
            default: glyph = 15'b000_000_000_000_000;
        endcase
    end
endfunction

//-------------------------------------------------------
// �����أ������ĸ��ֶ� / �ĸ����� / ��һ��
//-------------------------------------------------------
assign hraddr = x[9:2];                      // ÿ 4 ����һ�� bin

wire [9:0] cc6 = (x >= FX) ? (x - FX) : 10'd0;

//  ����ͼ���ˣ��߶� = ���� >> BAR_SHIFT���е� BAR_MAXH
wire [9:0] bar_h   = (hrdata_gr >> BAR_SHIFT) > {10'd0, BAR_MAXH}
                   ? BAR_MAXH
                   : hrdata_gr[9:0] >> BAR_SHIFT;
wire [9:0] bar_top = BAR_Y - bar_h;

reg        txt_on ;
reg  [2:0] txt_dig;
reg  [2:0] txt_nd ;
reg  [9:0] txt_row;

always @(*) begin
    txt_on  = 1'b0;
    txt_dig = 3'd0;
    txt_nd  = 3'd0;
    txt_row = 10'd0;

    if(y >= F0_Y && y < F0_Y + 10) begin
        txt_nd  = nd0;
        txt_row = y - F0_Y;
    end
    else if(y >= F1_Y && y < F1_Y + 10) begin
        txt_nd  = nd1;
        txt_row = y - F1_Y;
    end
    else if(y >= F2_Y && y < F2_Y + 10) begin
        txt_nd  = nd2;
        txt_row = y - F2_Y;
    end
    else if(y >= F3_Y && y < F3_Y + 10) begin
        txt_nd  = nd3;
        txt_row = y - F3_Y;
    end

    if(txt_nd != 3'd0) begin
        //  cc6 < 6*nd �����ֶ��ڣ�nd*4 + nd*2 = nd*6��
        if(cc6 < ({txt_nd, 2'b0} + {txt_nd, 1'b0})) begin
            if(cc6 < 10'd6)       txt_dig = 3'd0;
            else if(cc6 < 10'd12) txt_dig = 3'd1;
            else if(cc6 < 10'd18) txt_dig = 3'd2;
            else if(cc6 < 10'd24) txt_dig = 3'd3;
            else if(cc6 < 10'd30) txt_dig = 3'd4;
            else                  txt_dig = 3'd5;
            txt_on = 1'b1;
        end
    end
end

//  ���ַ������Ͻǵ�λ�ã������������кţ�
wire [9:0] cell_x = (txt_dig == 3'd0) ? 10'd0  : (txt_dig == 3'd1) ? 10'd6  :
                    (txt_dig == 3'd2) ? 10'd12 : (txt_dig == 3'd3) ? 10'd18 :
                    (txt_dig == 3'd4) ? 10'd24 : 10'd30;
wire [3:0] ccol = (cc6 >= cell_x) ? (cc6 - cell_x) : 4'd0;

wire [3:0] dg_sel = (y >= F0_Y && y < F0_Y + 10) ? dg0[txt_dig] :
                    (y >= F1_Y && y < F1_Y + 10) ? dg1[txt_dig] :
                    (y >= F2_Y && y < F2_Y + 10) ? dg2[txt_dig] : dg3[txt_dig];

wire [14:0] pat  = glyph(dg_sel);
wire [2:0]  rr3  = txt_row[3:1];             // �Ŵ� 2 ������к� 0..4
wire [2:0]  cc3  = ccol[2:0] >> 1;           // �Ŵ� 2 ������к� 0..2
//  bidx = (4-rr3)*3 + (2-cc3) = 14 - 3*rr3 - cc3��λ������ӿ���3bit �� 4*3=12 �����
wire [4:0]  bidx = 5'd14 - ({2'b0, rr3} * 5'd3) - {3'b0, cc3};
wire        gbit = pat[bidx];

//-------------------------------------------------------
// ���
//-------------------------------------------------------
wire bar_on = (x < 10'd256) && (y <= BAR_Y) && (y >= bar_top) && (hrdata_gr != 20'd0);

always @(posedge clk or negedge rst_n) begin
    if(!rst_n) begin
        osd_on    <= 1'b0;
        osd_color <= 16'd0;
    end
    else if(!en) begin
        osd_on    <= 1'b0;
        osd_color <= 16'd0;
    end
    else if(txt_on && gbit) begin
        osd_on    <= 1'b1;
        osd_color <= COL_TEXT;
    end
    else if(bar_on) begin
        osd_on    <= 1'b1;
        osd_color <= COL_BAR;
    end
    else begin
        osd_on    <= 1'b0;
        osd_color <= 16'd0;
    end
end

endmodule
