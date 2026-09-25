# -*- coding: utf-8 -*-
"""
patch_p12_tb.py -- 相位 14：多帧累积（temporal_acc）单元测试

用 8x4 的小尺寸实例（清空只要 32 拍），逐像素喂进去，验证四件事：
  1) 只命中 1 帧 -> 还不够（mask_o = 0）        「单帧噪声被拒绝」
  2) 再命中 1 帧 -> acc=2 => mask_o = 1          「连中两帧粘住目标」
  3) 之后一帧不亮 -> acc=1 => mask_o = 0          「灯走了会消失，不留残影」
  4) 新像素只亮 1 帧 -> mask_o = 0                「噪声不会被攒成假目标」
另外检查 x/y/de 与 mask_o 的 2 拍对齐（错位的话 blob 会整体横移）。
"""

import os

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
REL = 'sim/tb_armor_vision.v'

with open(os.path.join(ROOT, REL), 'rb') as fh:
    raw = fh.read()
t = raw.decode('gbk')
crlf = '\r\n' in t
t = t.replace('\r\n', '\n')

if 'u_tacc_test' in t:
    print('[skip] %s 已打过补丁' % REL)
    raise SystemExit(0)

#--------------------------------------------------------------------------
# 1) 实例（放在 UART 监视器之前，和 track_ab/ballistic 单测一个风格）
#--------------------------------------------------------------------------
inst = (
    "//  ---- P12 多帧累积单测（8x4 小尺寸，清空只要 32 拍）----\n"
    "reg         ta2_de   = 1'b0;\n"
    "reg  [2:0]  ta2_x    = 3'd0;\n"
    "reg  [2:0]  ta2_y    = 3'd0;\n"
    "reg         ta2_mask = 1'b0;\n"
    "wire [2:0]  ta2_xo, ta2_yo;\n"
    "wire        ta2_deo, ta2_masko;\n"
    "\n"
    "temporal_acc #(.WIDTH(8), .HEIGHT(4), .AW(3)) u_tacc_test (\n"
    "    .clk     (clk      ),\n"
    "    .rst_n   (rst_n    ),\n"
    "    .de      (ta2_de   ),\n"
    "    .x       (ta2_x    ),\n"
    "    .y       (ta2_y    ),\n"
    "    .mask_in (ta2_mask ),\n"
    "    .en      (1'b1     ),\n"
    "    .thr     (2'd2    ),\n"
    "    .clr     (1'b0     ),\n"
    "    .x_o     (ta2_xo   ),\n"
    "    .y_o     (ta2_yo   ),\n"
    "    .de_o    (ta2_deo  ),\n"
    "    .mask_o  (ta2_masko)\n"
    ");\n"
    "\n"
)
t = t.replace("//  115200 @ 25MHz = 217 拍/位；起始位下降沿后等 1.5 位再每 217 拍采一次\n",
              inst + "//  115200 @ 25MHz = 217 拍/位；起始位下降沿后等 1.5 位再每 217 拍采一次\n", 1)

#--------------------------------------------------------------------------
# 2) 逐像素驱动任务
#--------------------------------------------------------------------------
task_def = (
    "//  给多帧累积单测喂一个像素：de 只拉高 1 拍，2 拍后看输出（BRAM 同步读 1 拍 + 判据 1 拍）\n"
    "task ta2_px;\n"
    "    input [2:0] px;\n"
    "    input [2:0] py;\n"
    "    input       pm;\n"
    "    begin\n"
    "        @(negedge clk);\n"
    "        ta2_x = px; ta2_y = py; ta2_mask = pm; ta2_de = 1'b1;\n"
    "        @(negedge clk);\n"
    "        ta2_de = 1'b0;\n"
    "        repeat(2) @(posedge clk);\n"
    "    end\n"
    "endtask\n"
    "\n"
)
t = t.replace("initial begin\n    $display(\"=======================================================\");\n",
              task_def + "initial begin\n    $display(\"=======================================================\");\n", 1)

#--------------------------------------------------------------------------
# 3) 相位 14
#--------------------------------------------------------------------------
phase = (
    "    //=====================================================\n"
    "    $display(\"---- phase 14 : temporal_acc (P12) unit test ----\");\n"
    "    //=====================================================\n"
    "    repeat(60) @(posedge clk);          // 等自动清空走完（8x4 = 32 拍）\n"
    "    //  同一个像素：(2,1) 连亮两帧 -> acc=2 -> 被留下\n"
    "    ta2_px(3'd2, 3'd1, 1'b1);\n"
    "    chk(\"tacc_hit1\", {31'b0, ta2_masko}, 32'd0);   // 只亮 1 帧：还不够\n"
    "    ta2_px(3'd2, 3'd1, 1'b1);\n"
    "    chk(\"tacc_hit2\", {31'b0, ta2_masko}, 32'd1);   // 连中两帧：粘住\n"
    "    chk(\"tacc_align_x\", {29'd0, ta2_xo}, 32'd2);   // 坐标要跟着一起延 2 拍\n"
    "    chk(\"tacc_align_y\", {29'd0, ta2_yo}, 32'd1);\n"
    "    chk(\"tacc_align_de\", {31'b0, ta2_deo}, 32'd1);\n"
    "    //  灯走了：一帧不亮 -> acc 回到 1 -> 又判为没有\n"
    "    ta2_px(3'd2, 3'd1, 1'b0);\n"
    "    chk(\"tacc_decay\", {31'b0, ta2_masko}, 32'd0);\n"
    "    //  噪声：另一个像素只亮 1 帧 -> 必须被拒绝（不会被攒成假目标）\n"
    "    ta2_px(3'd5, 3'd2, 1'b1);\n"
    "    chk(\"tacc_noise\", {31'b0, ta2_masko}, 32'd0);\n"
    "    chk(\"tacc_noise_x\", {29'd0, ta2_xo}, 32'd5);\n"
    "\n"
)
t = t.replace("    if(err_cnt == 32'd0)\n        $display(\"==== ALL CHECKS PASSED ====\");\n",
              phase + "    if(err_cnt == 32'd0)\n        $display(\"==== ALL CHECKS PASSED ====\");\n", 1)

out = t.replace('\n', '\r\n') if crlf else t
with open(os.path.join(ROOT, REL), 'wb') as fh:
    fh.write(out.encode('gbk'))
with open(os.path.join(ROOT, REL), 'rb') as fh:
    if fh.read().decode('gbk') != out:
        raise SystemExit('**** 回读比对失败 ****')
print('[ok]   %s  %d -> %d bytes' % (REL, len(raw), len(out.encode('gbk'))))
