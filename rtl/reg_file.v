`timescale 1ns / 1ps
//****************************************************************************************//
// File name:           reg_file
// Descriptions:        ����ʱ��д�Ĵ����ļ���P2������ �� UART �Ĳ��������������ۺ�
//
//   Ϊʲô��Ҫ��
//     dart ��ÿ���Զ��� IP ���� AXI4-Lite��`*_S00_AXI.v`��+ Linux ��������ֵ������ʱ
//     ��д�ġ�����ԭ��ֻ�а��� + ����ܣ���һ������Ҫ��һ���ۺϣ�20 ���ӣ���
//     ��������ʡ�µķ��� ���� UART д�Ĵ�������λ�� / ��Ƭ���Ϸ�һ�� 4 �ֽ�����ɡ�
//
//   �����ʽ��4 �ֽڣ���
//     0xAA   addr   data   (addr ^ data)
//   У�鲻������������������д��������
//
//   дһ����ֵ����Ӱ�졸û�ᵽ�Ĳ��������ϵ�ʱȫ���ص�����Ĭ��ֵ��
//   ����ֻ��**д������һ��**����֮��armor_vision �Ż���üĴ��������ֵ ����
//   ûд������ȫ���ð�����Ϊ������Ĭ����Ϊ��� UART ֮ǰһģһ����
//
//   ��Դ��Լ 130 LUT / 220 FF��
//****************************************************************************************//
module reg_file (
    input              clk       ,
    input              rst_n     ,
    input              rx_done   ,
    input      [7:0]   rx_data   ,
    output reg [7:0]   r_th_g    ,
    output reg [7:0]   r_th_gr   ,
    output reg [7:0]   r_th_gb   ,
    output reg [7:0]   r_rel_sat ,
    output reg [7:0]   r_min_size,
    output reg [7:0]   r_aim_h   ,
    output reg [7:0]   r_ring_t  ,
    output reg [7:0]   r_ctrl    ,   // b0=����Ӧ b1=��ֵ b2=�ع�ջ� b3=��ֵ��ʾ b4=OSD
    output reg [7:0]   r_gate    ,
    output reg [7:0]   r_pct     ,
    output reg [7:0]   r_lead_q4 ,
    output reg [7:0]   r_drop_sc ,
    output reg [7:0]   r_tacc    ,
    output reg [7:0]   r_syn_spd ,   // 0x0D P13 合成靶标速度（有符号 Q4 px/帧）
    output reg [7:0]   r_syn_r   ,   // 0x0E P13 合成靶标半径（像素）
    output reg [7:0]   r_syn_en  ,   // 0x0F P13 1 = 用合成靶标代替相机
    output reg [7:0]   r_st_page ,   // 0x10 P13 数码管状态页
    output reg [7:0]   r_flags2   ,  // 0x12 P14 b0 = 强制打开 α-β 跟踪器
    output reg [7:0]   r_lead_auto,  // 0x11 P13 1 = 提前量由距离自动算   // 0x0C 多帧累积（b1:0=阈值 b7=强制清零）   // 0x0B 弹速修正（Q8，255 = 20m/s）   // 速度预测提前量（帧 x16，Q4）
    output reg         wr_pulse      // �в�����д������һ�����壨�ɽ� LED ��ʾ��
);

//localparam
localparam S_HDR = 2'd0, S_ADDR = 2'd1, S_DATA = 2'd2, S_CHK = 2'd3;

//reg define
reg  [1:0] state ;
reg  [7:0] addr_t;
reg  [7:0] data_t;

//*****************************************************
//**                    main code
//*****************************************************

always @(posedge clk or negedge rst_n) begin
    if(!rst_n) begin
        state    <= S_HDR;
        addr_t   <= 8'd0;
        data_t   <= 8'd0;
        wr_pulse <= 1'b0;
        r_th_g     <= 8'd100;
        r_th_gr    <= 8'd32;
        r_th_gb    <= 8'd32;
        r_rel_sat  <= 8'd20;
        r_min_size <= 8'd8;
        r_aim_h    <= 8'd116;   // = 372 & 0xFF，与 armor_vision 的 AIM_H_Q8 默认一致
        r_ring_t   <= 8'd2;
        r_ctrl     <= 8'h00;      // Ĭ��ȫ���¹��ܹرգ���Ϊ��Ķ�ǰһ�£�
        r_gate     <= 8'd96;
        r_pct      <= 8'd15;
        r_lead_q4  <= 8'd64;
        r_drop_sc  <= 8'd255;
        r_tacc     <= 8'h02;
        r_syn_spd  <= 8'd80;      // 5.0 px/帧（Q4 = 80）
        r_syn_r    <= 8'd60;      // 直径 120px：落在「推荐取景 100~130px」范围内
        r_syn_en   <= 8'd0;       // 默认用相机
        r_st_page  <= 8'd0;       // 默认正常显示页
        r_flags2   <= 8'd0;       // P14：默认不强制开跟踪器
        r_lead_auto<= 8'd1;       // 默认按距离自动算提前量      // 阈值 2（默认），不清零   // 4.0 帧（30fps 下约 133ms 提前量）
    end
    else begin
        wr_pulse <= 1'b0;

        case(state)
            S_HDR: if(rx_done && (rx_data == 8'hAA)) state <= S_ADDR;

            S_ADDR: if(rx_done) begin
                        addr_t <= rx_data;
                        state  <= S_DATA;
                    end

            S_DATA: if(rx_done) begin
                        data_t <= rx_data;
                        state  <= S_CHK;
                    end

            default: if(rx_done) begin          // S_CHK
                        state <= S_HDR;
                        if(rx_data == (addr_t ^ data_t)) begin
                            wr_pulse <= 1'b1;
                            case(addr_t)
                                8'h00: r_th_g     <= data_t;
                                8'h01: r_th_gr    <= data_t;
                                8'h02: r_th_gb    <= data_t;
                                8'h03: r_rel_sat  <= (data_t > 8'd100) ? 8'd100 : data_t;
                                8'h04: r_min_size <= data_t;
                                8'h05: r_aim_h    <= data_t;
                                8'h06: r_ring_t   <= data_t;
                                8'h07: r_ctrl     <= data_t;
                                8'h08: r_gate     <= data_t;
                                8'h09: r_pct      <= data_t;
                                8'h0A: r_lead_q4  <= data_t;
                                8'h0B: r_drop_sc  <= data_t;
                                8'h0C: r_tacc     <= data_t;
                                8'h0D: r_syn_spd  <= data_t;
                                8'h0E: r_syn_r    <= data_t;
                                8'h0F: r_syn_en   <= data_t;
                                8'h10: r_st_page  <= data_t;
                                8'h11: r_lead_auto<= data_t;
                                8'h12: r_flags2   <= data_t;
                                default: ;              // δ֪��ַ����
                            endcase
                        end
                    end
        endcase
    end
end

endmodule
