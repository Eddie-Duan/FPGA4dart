# -*- coding: utf-8 -*-
"""
patch_p12_fix.py -- 两件事：

1) 重建 rtl/temporal_acc.v
   这个文件被之前的 UTF-8->GBK 转换脚本二次编码弄坏了（832 个 U+FFFD），
   代码本身是 ASCII、完好无损，坏掉的只是中文注释。这里用 tools/_tacc_new.txt
   里的干净内容（逻辑与原来逐行一致）重写成 GBK，写后回读比对。
   教训：不要用「读进来当 GBK 再写 UTF-8」的转换器；务必 UTF-8 读 -> GBK 写。

2) 修 sim/tb_armor_vision.v
   a. UART 监视器收 68 字节（两帧），ur_n 从 6 bit 加宽到 7 bit；
   b. 原来的 `uart_seq == 0` 断言写过头了（监视器抓到的第一帧未必是上电第 0 帧，
      实测 seq=13）。改成两条更硬的检查：
        - 第二帧序号 = 第一帧序号 + 1（mod 256）
        - 帧 1 / 帧 2 的 CRC 用 testbench 自己的软件 CRC 对拍
          （覆盖 byte2..byte31，含帧序号），不再依赖固定魔数 0x8B12
   c. 顺便把两帧的原始字节 dump 出来，便于排查；
   d. 修正 ta2_px 任务的采样时刻：原来在 posedge 同一时刻读 ta2_masko，
      会和寄存器的更新撞竞争，改成在随后的 negedge 读。
"""

import io
import os
import re

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
os.chdir(ROOT)

# =====================================================================
# 1) 重建 temporal_acc.v
# =====================================================================
src = io.open('tools/_tacc_new.txt', encoding='utf-8').read().replace('\n', '\r\n')
try:
    gbk_bytes = src.encode('gbk')
except UnicodeEncodeError as e:
    raise SystemExit('新文件里有 GBK 放不下的字符：%s' % e)

if 'temporal_acc' not in src or 'acc_mem' not in src or 'endmodule' not in src:
    raise SystemExit('_tacc_new.txt 内容可疑，已中止')

io.open('rtl/temporal_acc.v', 'wb').write(gbk_bytes)
back = io.open('rtl/temporal_acc.v', 'rb').read().decode('gbk')
if back != src:
    raise SystemExit('**** temporal_acc.v 回读比对失败 ****')
print('[ok]   rtl/temporal_acc.v 重建为 GBK %d bytes' % len(gbk_bytes))

for tmp in ('tools/_tacc_new.txt', 'tools/_tacc_dump.txt'):
    if os.path.exists(tmp):
        os.remove(tmp)
        print('[ok]   删除临时文件 %s' % tmp)

# =====================================================================
# 2) 修 testbench
# =====================================================================
REL = 'sim/tb_armor_vision.v'
with open(REL, 'rb') as fh:
    raw = fh.read()
t = raw.decode('gbk')
crlf = '\r\n' in t
t = t.replace('\r\n', '\n')


def sub1(pat, rep, what, flags=0):
    """按正则替换，要求匹配次数恰好 1；用 lineno 检查时出错给出提示"""
    global t
    n = len(re.findall(pat, t, flags))
    if n != 1:
        raise SystemExit('%s：锚点匹配 %d 处（应为 1）' % (what, n))
    t = re.sub(pat, rep, t, count=1, flags=flags)
    print('[ok]   %s' % what)


# --- a) 监视器加宽到两帧 -------------------------------------------
sub1(r"reg  \[7:0\]  ur_b \[0:33\];.*",
     "reg  [7:0]  ur_b [0:67];   // 收两帧（34x2）：第二帧验序号递增与 CRC",
     'ur_b 数组 34 -> 68')

sub1(r"reg  \[5:0\]  ur_n    = 6'd0;.*",
     "reg  [6:0]  ur_n    = 7'd0;",
     'ur_n 位宽 6 -> 7 bit')

sub1(r"ur_act <= 1'b0; ur_done <= 1'b0; ur_n <= 6'd0;",
     "ur_act <= 1'b0; ur_done <= 1'b0; ur_n <= 7'd0;",
     'ur_n 复位值')

sub1(r"if\(ur_n < 6'd34\) begin\n                ur_b\[ur_n\] <= ur_sh;\n                ur_n <= ur_n \+ 6'd1;",
     "if(ur_n < 7'd68) begin\n                ur_b[ur_n] <= ur_sh;\n                ur_n <= ur_n + 7'd1;",
     '监视器写入门限 34 -> 68')

sub1(r"if\(ur_n == 6'd33\) ur_done <= 1'b1;.*",
     "if(ur_n == 7'd67) ur_done <= 1'b1;  // 收满两帧（68 字节）就冻结",
     '冻结条件 33 -> 67')

sub1(r'chk\("uart_nbytes", \{26\'d0, ur_n\}, 32\'d34\);',
     'chk("uart_nbytes", {25\'d0, ur_n}, 32\'d68);',
     'nbytes 期望 34 -> 68')

# --- b) 软件 CRC + 两帧打包 + 原始 dump ----------------------------
pay1 = ', '.join('ur_b[%d]' % i for i in range(2, 32))
pay2 = ', '.join('ur_b[%d]' % i for i in range(36, 66))
helper = (
    "\n"
    "//  ---- P12: 软件 CRC16/CCITT-FALSE，用来和硬件 CRC 对拍 ----\n"
    "//  把 byte2..byte31 拼成 240 bit 逐位算；这样不依赖「第一帧 seq 一定是 0」的假设，\n"
    "//  也能顺带指出「收到的字节序/覆盖范围」是否有错。\n"
    "integer      uk2;\n"
    "wire [239:0] ur_pay1 = { %s };\n"
    "wire [239:0] ur_pay2 = { %s };\n"
    "wire [15:0]  ur_c1   = { ur_b[32], ur_b[33] };\n"
    "wire [15:0]  ur_c2   = { ur_b[66], ur_b[67] };\n"
    "\n"
    "function [15:0] crc16_sw;\n"
    "    input [239:0] dat;\n"
    "    integer       i;\n"
    "    reg   [15:0]  c;\n"
    "    reg           msb;\n"
    "    begin\n"
    "        c = 16'hFFFF;\n"
    "        for(i = 239; i >= 0; i = i - 1) begin\n"
    "            msb = c[15] ^ dat[i];\n"
    "            c   = {c[14:0], 1'b0} ^ (msb ? 16'h1021 : 16'h0000);\n"
    "        end\n"
    "        crc16_sw = c;\n"
    "    end\n"
    "endfunction\n"
) % (pay1, pay2)
sub1(r"integer     uk;\n", "integer     uk;\n" + helper, '插入软件 CRC 函数与两帧打包')

# --- c) 换掉 uart_seq / uart_crc 两条断言 ---------------------------
new_seq = (
    "    //  帧序号：监视器抓到的第一帧未必是上电后第 0 帧，所以验「第二帧 = 第一帧 + 1」\n"
    "    chk(\"uart_seq_inc\", ({24'd0, ur_b[65]} - {24'd0, ur_b[31]}) & 32'hFF, 32'd1);\n"
    "    chk(\"uart2_hdr0\",   {24'd0, ur_b[34]}, 32'hA5);\n"
    "    chk(\"uart2_hdr1\",   {24'd0, ur_b[35]}, 32'h5A);"
)
sub1(r'    chk\("uart_seq".*', new_seq, 'uart_seq -> uart_seq_inc')

new_crc = (
    "    //  CRC 用软件 CRC 对拍（覆盖 byte2..byte31），两帧都验\n"
    "    chk(\"uart_crc_sw\",  {16'd0, crc16_sw(ur_pay1)}, {16'd0, ur_c1});\n"
    "    chk(\"uart2_crc_sw\", {16'd0, crc16_sw(ur_pay2)}, {16'd0, ur_c2});\n"
    "    $write(\"  raw_frame1:\");\n"
    "    for(uk2 = 0; uk2 < 34; uk2 = uk2 + 1) $write(\" %02x\", ur_b[uk2]);\n"
    "    $write(\"\\n  raw_frame2:\");\n"
    "    for(uk2 = 34; uk2 < 68; uk2 = uk2 + 1) $write(\" %02x\", ur_b[uk2]);\n"
    "    $write(\"\\n\");"
)
sub1(r'    chk\("uart_crc".*', new_crc, 'uart_crc -> 两帧软件 CRC 对拍 + 原始 dump')

# --- d) ta2_px 采样时刻 ---------------------------------------------
sub1(r"        ta2_de = 1'b0;\n        repeat\(2\) @\(posedge clk\);\n    end\nendtask",
     "        ta2_de = 1'b0;\n"
     "        repeat(2) @(posedge clk);   // 第 2 个 posedge 上 mask_r 刚更新\n"
     "        @(negedge clk);             // 挪到半个周期后再读，避开与 posedge 的竞争\n"
     "    end\n"
     "endtask",
     'ta2_px 采样挪到 negedge')

out = t.replace('\n', '\r\n') if crlf else t
with open(REL, 'wb') as fh:
    fh.write(out.encode('gbk'))
with open(REL, 'rb') as fh:
    if fh.read().decode('gbk') != out:
        raise SystemExit('**** tb 回读比对失败 ****')
print('[ok]   %s  %d -> %d bytes' % (REL, len(raw), len(out.encode('gbk'))))
print('=== P12 修补完成 ===')
