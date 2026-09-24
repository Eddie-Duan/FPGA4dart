# -*- coding: utf-8 -*-
"""
patch_p0_stat.py -- P0：把 vision_stat 仪表盘接进 armor_vision

改什么：在 `armor_vision.v` 末尾（LED 段之后、endmodule 之前）插入一段
        vision_stat 例化 + 对应 wire。

为什么用 dont_touch：
        P0 阶段这些统计量还没有下游消费者（UART 在 P1 才接），综合器会把整个
        模块优化掉，mark_debug 也就抓不到任何东西。用 dont_touch 先把实例钉住；
        P1 接上 UART 之后可以去掉。mark_debug 属性已经在 vision_stat 内部打好。

安全性：GBK 解码 -> 纯 ASCII 锚点替换 -> GBK 编码 -> 回读比对。
        可重复执行（已插入过会自动跳过）。

用法：python tools/patch_p0_stat.py
"""

import os

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
TARGET = os.path.join(ROOT, 'rtl', 'armor_vision.v')

ANCHOR = "assign led[3] = ~(bond_valid ? 1'b1 : hb);"

INSERT = """
//-------------------------------------------------------
// (10) 仪表盘：帧率 / 帧长 / 掩码像素数 / 命中率
//      纯观测模块，不参与判决、不改画面。
//      统计量在 P0 阶段还没有下游消费者，所以用 dont_touch 把实例钉住，
//      否则综合器会整块优化掉，mark_debug 抓不到东西；
//      P1 接上 UART 之后这两个属性可以删掉。
//      mark_debug 已打在 vision_stat 的输出上：
//      Vivado -> Open Synthesized Design -> Set Up Debug 会自动认出来。
//-------------------------------------------------------
wire [31:0] st_frame_cyc  ;
wire [15:0] st_fps        ;
wire [15:0] st_frame_lines;
wire [31:0] st_mask_cnt   ;
wire [15:0] st_hit_frames ;
wire [15:0] st_miss_frames;
wire        st_frame_tick ;

(* keep_hierarchy = "yes", dont_touch = "true" *)
vision_stat #(
    .CLK_FREQ (CLK_FREQ)
) u_vision_stat (
    .clk         (clk           ),
    .rst_n       (rst_n         ),
    .vsync       (vsync         ),
    .de          (de_v          ),
    .mask        (mask_d        ),
    .bond_valid  (bond_valid    ),
    .frame_cyc   (st_frame_cyc  ),
    .fps         (st_fps        ),
    .frame_lines (st_frame_lines),
    .mask_cnt    (st_mask_cnt   ),
    .hit_frames  (st_hit_frames ),
    .miss_frames (st_miss_frames),
    .frame_tick  (st_frame_tick )
);
"""

#  create_file 在本机写出来的是 CRLF，多行字符串里的 '\r\n' 会让
#  「统一还原 CRLF」那步产生 '\r\r\n' —— 先归一化掉。
INSERT = INSERT.replace('\r\n', '\n').replace('\r', '\n')


def main():
    with open(TARGET, 'rb') as fh:
        raw = fh.read()
    text = raw.decode('gbk')
    crlf = '\r\n' in text
    norm = text.replace('\r\n', '\n')

    if 'u_vision_stat' in norm:
        print('[skip] rtl/armor_vision.v 已经接好 vision_stat')
        return

    if norm.count(ANCHOR) != 1:
        raise SystemExit('锚点匹配 %d 处（应为 1 处），放弃' % norm.count(ANCHOR))

    #  一律在 \n 域里插入，最后一次性还原成原本的换行风格
    norm = norm.replace(ANCHOR, ANCHOR + INSERT)

    out_text = norm.replace('\n', '\r\n') if crlf else norm
    out = out_text.encode('gbk')
    with open(TARGET, 'wb') as fh:
        fh.write(out)

    with open(TARGET, 'rb') as fh:
        back = fh.read().decode('gbk')
    if back != out_text:
        raise SystemExit('**** 回读比对失败，请从版本控制还原 ****')

    print('[ok]   rtl/armor_vision.v  GBK %d -> %d bytes (crlf=%s)' % (len(raw), len(out), crlf))
    print('       插入 vision_stat 例化（dont_touch 保护，供 ILA 观察）')


if __name__ == '__main__':
    main()
