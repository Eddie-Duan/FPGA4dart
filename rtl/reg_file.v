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
    output reg [7:0]   r_drop_sc ,   // 0x0B 弹速修正（Q8，255 = 20m/s）   // 速度预测提前量（帧 x16，Q4）
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
        r_drop_sc  <= 8'd255;   // 4.0 帧（30fps 下约 133ms 提前量）
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
                                default: ;              // δ֪��ַ����
                            endcase
                        end
                    end
        endcase
    end
end

endmodule
