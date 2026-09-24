# -*- coding: utf-8 -*-
"""
patch_p18_wire.py -- 把 P0~P8 的新端口接起来，并更新测试台

1) rtl/ov5640_lcd.v
   armor_vision 新增了 uart_rxd / uart_txd。这里**故意不接引脚**：
   板上 USB-UART 的引脚要按实际接线再定，现在贸然加顶层端口 + 未约束引脚，
   实现阶段会报一大堆 unconstrained IO 的麻烦（我们刚被「未标定改动」坑过，不再犯）。
   所以 rxd 固定接 1'b1（永远收不到数据 -> 寄存器保持默认值，行为与改动前一致），
   txd 悬空。等确认了引脚，再在 pin.xdc 里约束并把这两根线引到顶层。

2) sim/tb_armor_vision.v
   a) 主实例补上 uart 端口
   b) 加 chk_near 任务（团块跟踪报的是**真实外延**，而旧投影有 TH_MIN=4 裁剪，
      边界会差 1~2 像素，不适合精确比较；中心/有效性仍然精确比较）
   c) 加 phase 9：track_ab 的独立单元测试（门控 + 持久性 + 丢失撤销）

安全性：GBK 解码 -> 精确字符串替换 -> GBK 编码 -> 回读比对。可重复执行。
用法：python tools/patch_p18_wire.py
"""

import os

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)


def edit(rel, pairs, skip_token):
    path = os.path.join(ROOT, rel.replace('/', os.sep))
    with open(path, 'rb') as fh:
        raw = fh.read()
    text = raw.decode('gbk')
    crlf = '\r\n' in text
    norm = text.replace('\r\n', '\n')

    if skip_token in norm:
        print('[skip] %s 已经处理过' % rel)
        return

    for old, new in pairs:
        old = old.replace('\r\n', '\n')
        new = new.replace('\r\n', '\n')
        if norm.count(old) != 1:
            raise SystemExit('%s: 锚点匹配 %d 处（应为 1）:\n%s'
                             % (rel, norm.count(old), old[:120]))
        norm = norm.replace(old, new)

    out_text = norm.replace('\n', '\r\n') if crlf else norm
    out = out_text.encode('gbk')
    with open(path, 'wb') as fh:
        fh.write(out)
    with open(path, 'rb') as fh:
        if fh.read().decode('gbk') != out_text:
            raise SystemExit('**** %s 回读比对失败 ****' % rel)
    print('[ok]   %s  GBK %d -> %d bytes' % (rel, len(raw), len(out)))


# ---------------------------------------------------------------------------
# 1) ov5640_lcd.v
# ---------------------------------------------------------------------------
PAIRS_TOP = [
    ("""    .center_x   (vision_cx        ),
    .center_y   (vision_cy        )
);
endmodule""",
     """    .center_x   (vision_cx        ),
    .center_y   (vision_cy        ),
    //  UART（P1 结果上报 / P2 参数写入）—— 这里先不接引脚：
    //  板上 USB-UART 的引脚要按实际接线再定；现在加顶层端口 + 未约束引脚，
    //  实现阶段会变成一堆 unconstrained IO 的麻烦。
    //  rxd 固定 1 -> 永远收不到数据 -> 寄存器保持工程默认值，行为与改动前一致。
    //  txd 悬空 -> 综合会把 UART 发送链优化掉（要用就在 pin.xdc 里约束后再引到顶层）。
    .uart_rxd   (1'b1             ),
    .uart_txd   (                 )
);
endmodule"""),
]

# ---------------------------------------------------------------------------
# 2) tb_armor_vision.v
# ---------------------------------------------------------------------------
PAIRS_TB = [
    #  a) 主实例的 uart 端口已由 tools/_fix_tb_inst.py 补上（那一步同时修了 P0 留下的
    #     「测试实例被插进端口列表」的结构错误），这里不重复添加。

    #  b) chk_near 任务
    ("""// 区间检查：像掩码像素数这种值不适合精确比较（闭运算会略微填补离散化的阶梯）
task chk_range;""",
     """// 邻近检查：团块跟踪报的是**全部亮像素的真实外延**，而旧的直方图投影有
// TH_MIN=4 的裁剪（边界上只有 1~3 个亮像素的列会被丢掉），所以边界会差 1~2 像素。
// 这不是错误，而是定义变了：现在报的是真实范围。中心/有效性仍然精确比较。
task chk_near;
    input [8*16-1:0] name;
    input [31:0]     got;
    input [31:0]     exp;
    input [31:0]     tol;
    reg   [31:0]     dlo;
    begin
        dlo = (got > exp) ? (got - exp) : (exp - got);
        if(dlo <= tol)
            $display("  [OK]   %0s = %0d (expect %0d +-%0d)", name, got, exp, tol);
        else begin
            err_cnt = err_cnt + 32'd1;
            $display("  [FAIL] %0s = %0d, expect %0d +-%0d", name, got, exp, tol);
        end
    end
endtask

// 区间检查：像掩码像素数这种值不适合精确比较（闭运算会略微填补离散化的阶梯）
task chk_range;"""),

    #  c) phase 1 边界改为邻近比较
    ("""    chk("bond_l",     u_armor_vision.bl    , EXP_L   );
    chk("bond_r",     u_armor_vision.br    , EXP_R   );
    chk("bond_t",     u_armor_vision.bt    , EXP_T   );
    chk("bond_b",     u_armor_vision.bb    , EXP_B   );
    chk("bond_w",     u_armor_vision.bond_w, EXP_W   );
    chk("center_x",   center_x             , EXP_CX  );
    chk("center_y",   center_y             , EXP_CY  );
    chk("aim_x",      aim_x                , EXP_CX  );
    chk("aim_y",      aim_y                , EXP_AY  );""",
     """    chk_near("bond_l",  u_armor_vision.bl    , EXP_L   , 32'd2);
    chk_near("bond_r",  u_armor_vision.br    , EXP_R   , 32'd2);
    chk_near("bond_t",  u_armor_vision.bt    , EXP_T   , 32'd2);
    chk_near("bond_b",  u_armor_vision.bb    , EXP_B   , 32'd2);
    chk_near("bond_w",  u_armor_vision.bond_w, EXP_W   , 32'd3);
    chk("center_x",   center_x             , EXP_CX  );
    chk("center_y",   center_y             , EXP_CY  );
    chk("aim_x",      aim_x                , EXP_CX  );
    chk_near("aim_y",   aim_y              , EXP_AY  , 32'd2);
    chk_near("cent_x",  u_armor_vision.cent_x, EXP_CX, 32'd3);
    chk_near("cent_y",  u_armor_vision.cent_y, EXP_CY, 32'd3);
    //  填充率：半径 100 的圆 -> area/(w*h) 约 31417/39601 = 0.793 -> fill_q8 约 203
    chk_range("fill_q8", u_armor_vision.fill_q8, 32'd185, 32'd215);
    chk("blob_cnt",     u_armor_vision.blob_cnt, 32'd1);
    chk("blob_area>0",  (u_armor_vision.blob_area > 32'd20000), 32'd1);"""),

    #  d) phase 2 边界改为邻近比较
    ("""    chk("bond_l",     u_armor_vision.bl    , GLA_L   );
    chk("bond_r",     u_armor_vision.br    , GLA_R   );
    chk("bond_w",     u_armor_vision.bond_w, GLA_W   );
    chk("bond_t",     u_armor_vision.bt    , EXP_T   );
    chk("bond_b",     u_armor_vision.bb    , EXP_B   );
    chk("center_y",   center_y             , EXP_CY  );
    chk("aim_y",      aim_y                , EXP_AY  );""",
     """    chk_near("bond_l", u_armor_vision.bl    , GLA_L   , 32'd3);
    chk_near("bond_r", u_armor_vision.br    , GLA_R   , 32'd3);
    chk_near("bond_w", u_armor_vision.bond_w, GLA_W   , 32'd4);
    chk_near("bond_t", u_armor_vision.bt    , EXP_T   , 32'd2);
    chk_near("bond_b", u_armor_vision.bb    , EXP_B   , 32'd2);
    chk("center_y",    center_y             , EXP_CY  );
    chk_near("aim_y",  aim_y                , EXP_AY  , 32'd2);"""),

    ("""    chk("bond_l",       u_armor_vision.bl, EXP_L   );
    chk("inside_green", cap_in           , GREEN_PIX);""",
     """    chk_near("bond_l",  u_armor_vision.bl, EXP_L   , 32'd2);
    chk("inside_green", cap_in           , GREEN_PIX);"""),

    #  e) track_ab 单元测试实例（插在 initial 主流程之前；用 ASCII 锚点，
    #     因为中文注释在不同转换步骤后字节可能不一致，容易匹配不上）
    ("""initial begin""",
     """//-------------------------------------------------------
// P4 单元测试：单独驱动 track_ab，验证门控 + 持久性 + 丢失撤销
//   （主实例里 TRK_EN=0 走逐帧路径，所以必须另起一个实例才能测到跟踪逻辑）
//-------------------------------------------------------
reg         ta_v_in ;
reg  [9:0]  ta_cx_i, ta_cy_i, ta_ay_i;
reg         ta_vsync;
wire        ta_valid;
wire [9:0]  ta_cx_o, ta_cy_o, ta_ax_o, ta_ay_o;
wire [4:0]  ta_lost ;

track_ab #(
    .AW (10), .WIDTH(800), .HEIGHT(480),
    .GATE (96), .HIT_N (2), .LOST_N (6)
) u_track_test (
    .clk       (clk       ),
    .rst_n     (rst_n     ),
    .vsync     (ta_vsync  ),
    .raw_valid (ta_v_in   ),
    .raw_cx    (ta_cx_i   ),
    .raw_cy    (ta_cy_i   ),
    .raw_ay    (ta_ay_i   ),
    .valid     (ta_valid  ),
    .cx        (ta_cx_o   ),
    .cy        (ta_cy_o   ),
    .ax        (ta_ax_o   ),
    .ay        (ta_ay_o   ),
    .lost_cnt  (ta_lost   )
);

//  送一帧给 track_ab（rise + fall 都造出来）
task ta_frame;
    input v;
    begin
        ta_v_in = v;
        ta_vsync = 1'b1; repeat(4) @(posedge clk);
        ta_vsync = 1'b0; repeat(4) @(posedge clk);
    end
endtask

initial begin"""),

    #  f) phase 9
    ("""    chk      ("t_frame_lines", t_frame_lines                 , 32'd480   );""",
     """    chk      ("t_frame_lines", t_frame_lines                 , 32'd480   );

    //=====================================================
    $display("---- phase 9 : track_ab unit test (P4) ----");
    //=====================================================
    ta_cx_i = 10'd400; ta_cy_i = 10'd240; ta_ay_i = 10'd190;
    ta_v_in = 1'b0; ta_vsync = 1'b0;
    repeat(8) @(posedge clk);

    //  连续 2 帧命中 -> HIT_N=2 -> valid 拉高
    ta_frame(1'b1);
    chk("ta_hit1_valid0", {31'b0, ta_valid}, 32'd0);   // 只命中 1 帧还不够
    ta_frame(1'b1);
    chk("ta_hit2_valid1", {31'b0, ta_valid}, 32'd1);
    chk_near("ta_cx", ta_cx_o, 32'd400, 32'd6);

    //  连续 3 帧丢失 -> 还没到 LOST_N=6 -> 保持有效（不跳变）
    ta_frame(1'b0);
    ta_frame(1'b0);
    ta_frame(1'b0);
    chk("ta_hold_valid",  {31'b0, ta_valid}, 32'd1);

    //  突然出现在 600（离预测位置 200 像素 > GATE=96）-> 被门控拒掉
    ta_cx_i = 10'd600;
    ta_frame(1'b1);
    chk("ta_gate_reject", {31'b0, ta_valid}, 32'd1);   // 仍然有效，但没被拉过去
    chk("ta_gate_lost",   {27'b0, ta_lost},  32'd4);
    chk_near("ta_not_jump", ta_cx_o, 32'd400, 32'd40);

    //  再丢 3 帧 -> 累计 7 >= LOST_N -> 撤销
    ta_cx_i = 10'd400;
    ta_frame(1'b0);
    ta_frame(1'b0);
    ta_frame(1'b0);
    chk("ta_drop_valid",  {31'b0, ta_valid}, 32'd0);"""),
]


def main():
    edit('rtl/ov5640_lcd.v', PAIRS_TOP, 'uart_rxd')
    edit('sim/tb_armor_vision.v', PAIRS_TB, 'u_track_test')
    print('done.')


if __name__ == '__main__':
    main()
