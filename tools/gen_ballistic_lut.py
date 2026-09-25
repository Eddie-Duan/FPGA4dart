# -*- coding: utf-8 -*-
"""
gen_ballistic.py -- 生成 rtl/ballistic.v（距离反推 + 弹道下坠补偿）

【为什么可以用两张 1/w 查表搞定】
  相机没标定之前，唯一可用的距离线索是「灯的表观宽度 w」：
      dist_mm = f_px * D_lamp / w
  代入 f_px = 2570（OV5640 800px 画幅 + 5mm 级镜头，见 doc §13 的推导）、
       D_lamp = 55mm（RM 靶标绿灯直径）：
      dist_cm = 14135 / w
  弹道下坠是【世界坐标】的量，但补偿要的是【像素】：
      dist_m   = dist_cm/100
      t        = dist_m / v0
      drop_m   = g*t^2/2
      px_per_mm= w / 55           <- 注意这一项也含 w
      drop_px  = drop_m*1000 * w/55
               = (g/2) * (14135/(100*v0*1000*w))^2 * 1000 * w/55
  化到最简，w 只剩一次幂：
      drop_px = 4454.5 / w        （v0 = 20 m/s 时）
  -> 两张 256 项的表都只是 1/w，零乘法、零除法、时序零风险。
  实际弹速不同时不用重新综合：写 UART 0x0C 的 DROP_SCALE（Q8）
      drop = (drop_base * DROP_SCALE) >> 8，DROP_SCALE = 256*(20/v0)^2

【用法】python tools/gen_ballistic_lut.py       # 覆盖生成 rtl/ballistic.v（UTF-8）
        然后 python tools/add_source.py rtl/ballistic.v   # 转 GBK + 注册进 .xpr
"""

import os

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)

F_PX = 2570.0        # 焦距（像素），见 doc/vision_pipeline.md §13
D_LAMP = 55.0        # 绿灯直径 mm
G = 9.81             # m/s^2
V0_REF = 20.0        # 基准弹速 m/s（DROP_SCALE = 256 时对应的弹速）
W_MIN = 8            # 小于这个宽度距离不可信（表外推）

K_DIST = F_PX * D_LAMP / 10.0                     # mm -> cm
assert abs(K_DIST - 14135.0) < 2.0, K_DIST


def dist_cm(w):
    return K_DIST / w


def drop_px(w, v0=V0_REF):
    d_m = (K_DIST / w) / 100.0
    t = d_m / v0
    return (0.5 * G * t * t) * 1000.0 * (w / D_LAMP)


def main():
    dist_tab = [min(65535, int(round(dist_cm(w)))) if w else 0 for w in range(256)]
    drop_tab = [min(65535, int(round(drop_px(w)))) if w else 0 for w in range(256)]

    #  自检：化简式 drop = 4454.5/w 对不对（w=28 -> 5m 靶）
    for w in (28, 50, 100, 200):
        a = drop_px(w)
        b = 4454.5 / w
        assert abs(a - b) < 0.5, (w, a, b)

    dist_lines = "\n".join(
        "        DIST_MEM[%3d] = 16'd%5d;" % (w, dist_tab[w]) for w in range(256))
    drop_lines = "\n".join(
        "        DROP_MEM[%3d] = 16'd%5d;" % (w, drop_tab[w]) for w in range(256))

    verilog = '''`timescale 1ns / 1ps
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
localparam [AW:0] W_MIN = ''' + str(W_MIN) + ''';   // 宽度下限（低于此距离外推不可信）

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
''' + dist_lines + '''
end

initial begin
''' + drop_lines + '''
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
'''

    out = os.path.join(ROOT, 'rtl', 'ballistic.v')
    with open(out, 'w', encoding='utf-8', newline='\r\n') as fh:
        fh.write(verilog)
    print('[gen] %s (%d bytes)' % (out, len(verilog)))
    print('      表校验：w=28(5m)  dist=%dcm drop=%dpx' % (dist_tab[28], drop_tab[28]))
    print('               w=100(1.4m) dist=%dcm drop=%dpx' % (dist_tab[100], drop_tab[100]))
    print('               w=200(0.7m) dist=%dcm drop=%dpx' % (dist_tab[200], drop_tab[200]))


if __name__ == '__main__':
    main()
