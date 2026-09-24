# -*- coding: utf-8 -*-
"""
patch_p0_tb.py -- P0：给 tb_armor_vision 加 vision_stat 的自检

加三样东西：
  1) chk_range 任务         —— 掩码像素数这类值不适合精确比较
  2) fps 独立验证实例       —— vision_stat 的 fps 需要「1 秒窗口」才有输出，
                              仿真里不可能真跑 1 秒；这里用 CLK_FREQ = 2 个帧周期
                              再造一个实例，窗口正好 2 帧 -> fps 恒为 2，可精确断言
  3) phase 8 检查           —— frame_lines / frame_cyc / mask_cnt / 命中率

安全性：GBK 解码 -> ASCII 锚点替换 -> GBK 编码 -> 回读比对。
        可重复执行（已插入过会自动跳过）。
用法：python tools/patch_p0_tb.py
"""

import os

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
TARGET = os.path.join(ROOT, 'sim', 'tb_armor_vision.v')

ANCHOR_TASK = "task wait_frames;"
ANCHOR_INST = "    .aim_y      (aim_y      )\n);"
ANCHOR_PHASE = "    if(err_cnt == 32'd0)"

INSERT_TASK = """// 区间检查：像掩码像素数这种值不适合精确比较（闭运算会略微填补离散化的阶梯）
task chk_range;
    input [8*16-1:0] name;
    input [31:0]     got;
    input [31:0]     lo;
    input [31:0]     hi;
    begin
        if((got >= lo) && (got <= hi))
            $display("  [OK]   %0s = %0d in [%0d, %0d]", name, got, lo, hi);
        else begin
            err_cnt = err_cnt + 32'd1;
            $display("  [FAIL] %0s = %0d NOT in [%0d, %0d]", name, got, lo, hi);
        end
    end
endtask

"""

INSERT_INST = """
//-------------------------------------------------------
// P0：fps 逻辑的独立验证实例
//   vision_stat 的 fps 要「1 秒窗口」才有输出，仿真里不可能真跑 1 秒。
//   这里用 CLK_FREQ = 2*(H_TOTAL*V_TOTAL) 再造一个实例：窗口正好等于 2 个帧周期
//   -> fps 应恒为 2，可以精确断言（比断言 1 强，能排除「计数器卡住」的巧合）。
//-------------------------------------------------------
wire [31:0] t_frame_cyc  ;
wire [15:0] t_fps        ;
wire [15:0] t_frame_lines;
wire [31:0] t_mask_cnt   ;
wire [15:0] t_hit_frames ;
wire [15:0] t_miss_frames;
wire        t_frame_tick ;

vision_stat #(
    .CLK_FREQ (2*1056*525)              // 窗口 = 2 个帧周期 -> fps 恒为 2
) u_vision_stat_test (
    .clk         (clk                    ),
    .rst_n       (rst_n                  ),
    .vsync       (vsync                  ),
    .de          (u_armor_vision.de_v    ),
    .mask        (u_armor_vision.mask_d  ),
    .bond_valid  (bond_valid             ),
    .frame_cyc   (t_frame_cyc            ),
    .fps         (t_fps                  ),
    .frame_lines (t_frame_lines          ),
    .mask_cnt    (t_mask_cnt             ),
    .hit_frames  (t_hit_frames           ),
    .miss_frames (t_miss_frames          ),
    .frame_tick  (t_frame_tick           )
);
"""

INSERT_PHASE = """    //=====================================================
    $display("---- phase 8 : vision_stat instrumentation (P0) ----");
    $display("     frame period = H_TOTAL*V_TOTAL = 1056*525 = 554400 clk");
    //=====================================================
    chk      ("frame_lines",   u_armor_vision.st_frame_lines , 32'd480    );
    chk      ("frame_cyc",     u_armor_vision.st_frame_cyc   , 32'd554400 );
    // 绿盘半径 100 -> 面积约 31417；闭运算会填补离散化阶梯，略微变大
    chk_range("mask_cnt",      u_armor_vision.st_mask_cnt    , 32'd30000, 32'd33000);
    chk      ("hit_frames!=0", (u_armor_vision.st_hit_frames  != 16'd0), 32'd1);
    chk      ("miss_frames!=0",(u_armor_vision.st_miss_frames != 16'd0), 32'd1);
    // 独立实例：窗口正好 2 个帧周期 -> fps 恒为 2，顺带再验一次 frame_lines
    chk      ("t_fps",         t_fps                         , 32'd2     );
    chk      ("t_frame_lines", t_frame_lines                 , 32'd480   );

"""


def main():
    with open(TARGET, 'rb') as fh:
        raw = fh.read()
    text = raw.decode('gbk')
    crlf = '\r\n' in text
    norm = text.replace('\r\n', '\n')

    if 'u_vision_stat_test' in norm:
        print('[skip] sim/tb_armor_vision.v 已经加过 P0 自检')
        return

    def ins(anchor, block, what, count_expected=1):
        nonlocal norm
        if norm.count(anchor) != count_expected:
            raise SystemExit('锚点「%s」匹配 %d 处（应为 %d），放弃'
                             % (what, norm.count(anchor), count_expected))
        norm = norm.replace(anchor, block + anchor)

    ins(ANCHOR_TASK, INSERT_TASK, 'task wait_frames')
    ins(ANCHOR_INST, INSERT_INST, '主实例 aim_y 端口')
    ins(ANCHOR_PHASE, INSERT_PHASE, 'err_cnt 总结')

    out_text = norm.replace('\n', '\r\n') if crlf else norm
    out = out_text.encode('gbk')
    with open(TARGET, 'wb') as fh:
        fh.write(out)

    with open(TARGET, 'rb') as fh:
        if fh.read().decode('gbk') != out_text:
            raise SystemExit('**** 回读比对失败，请从版本控制还原 ****')

    print('[ok]   sim/tb_armor_vision.v  GBK %d -> %d bytes (crlf=%s)'
          % (len(raw), len(out), crlf))
    print('       加：chk_range 任务 + fps 独立实例 + phase 8')


if __name__ == '__main__':
    main()
