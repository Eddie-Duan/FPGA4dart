# -*- coding: utf-8 -*-
"""
patch_p12_fix2.py -- 修 temporal_acc 的两个真问题（单元测试发现的）

1) 写地址错一拍（真 bug）
   `waddr` 原来接 `adr_d`（延 2 拍），但写使能 `we = de_d`（延 1 拍）、写数据
   `wdata = acc_nx` 也是延 1 拍出来的 -> 结果是「把当前像素的新值写到上一个像素的地址」。
   连续像素流下表现为累积掩码整体左移 1 像素、最右一列永远不累积。
   修法：`waddr` 改用 `adr_w`（延 1 拍），与 we/wdata 同拍；`adr_d` 不再需要，删掉。

2) 行首地址写死 ×800
   `row_base = ym1*800` 是写死的，`WIDTH` 参数只管 DEPTH -> 用小 WIDTH 做单元测试时
   地址全部越界（读出来是 X），单元测试根本没法写。改成 `ym1 * WIDTH`（WIDTH 是常量，
   综合会化成移位相加，见 sim/tb_tacc.v 的头注释）。

顺带把主测试台的相位 14 采样时刻改对：像素是在「那个正沿」被采样的，输出在下一拍有效，
原来多等了 1 拍（读到 de_o=0）。

RTL 是 GBK：必须字节级改 + 回读比对。
"""

import os

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)


def edit(rel, pairs, crlf_keep=True):
    """按 ASCII/GBK 锚点做替换（str 级），要求每处唯一，最后按 GBK 写回并回读比对"""
    p = os.path.join(ROOT, rel)
    with open(p, 'rb') as fh:
        raw = fh.read()
    t = raw.decode('gbk')
    crlf = '\r\n' in t
    t = t.replace('\r\n', '\n')
    for old, new, what in pairs:
        n = t.count(old)
        if n != 1:
            raise SystemExit('%s / %s：锚点匹配 %d 处（应为 1）' % (rel, what, n))
        t = t.replace(old, new)
        print('[ok]   %s' % what)
    out = t.replace('\n', '\r\n') if crlf else t
    with open(p, 'wb') as fh:
        fh.write(out.encode('gbk'))
    with open(p, 'rb') as fh:
        if fh.read().decode('gbk') != out:
            raise SystemExit('**** %s 回读比对失败 ****' % rel)
    print('[ok]   %s  %d -> %d bytes' % (rel, len(raw), len(out.encode('gbk'))))


# =====================================================================
# 1) RTL
# =====================================================================
edit('rtl/temporal_acc.v', [
    #  a) 行首地址参数化
    ("wire [20:0] row_base = ({11'd0, ym1} << 9) + ({11'd0, ym1} << 8) + ({11'd0, ym1} << 5);",
     "//  这里必须用 WIDTH（而不是写死 800）：否则用小 WIDTH 做单元测试时地址会全部越界\n"
     "//  WIDTH 是常量（800 = 512+256+32），综合会化成移位相加，不会真的放乘法器\n"
     "wire [20:0] row_base = {{(21-AW){1'b0}}, ym1} * WIDTH;",
     'row_base 用 WIDTH 参数化'),

    #  b) 删掉 adr_d
    ("reg  [20:0] adr_w   ;\nreg  [20:0] adr_d   ;\n",
     "reg  [20:0] adr_w   ;\n",
     '删掉 adr_d 声明'),

    ("        adr_w   <= 21'd0;\n        adr_d   <= 21'd0;\n",
     "        adr_w   <= 21'd0;\n",
     '删掉 adr_d 复位'),

    ("        adr_w   <= adr_nx;\n        adr_d   <= adr_w;\n",
     "        adr_w   <= adr_nx;              // 写地址：与 we/wdata 同为「延 1 拍」\n",
     '删掉 adr_d 打拍'),

    #  c) 写地址改用 adr_w
    ("wire [20:0] waddr = clr_run ? clr_adr : adr_d;",
     "//  写地址必须用 adr_w（延 1 拍）：它和 we(=de_d)、wdata(=acc_nx) 同一拍，\n"
     "//  而 acc_q 是在这个地址读出的下一拍到 —— 三者对齐才不会把新值写到上一个像素\n"
     "wire [20:0] waddr = clr_run ? clr_adr : adr_w;",
     'waddr 改用 adr_w'),
])

# =====================================================================
# 2) 主测试台相位 14：采样时刻改成「正沿后半个周期」
# =====================================================================
p = os.path.join(ROOT, 'sim/tb_armor_vision.v')
with open(p, 'rb') as fh:
    raw = fh.read()
t = raw.decode('gbk')
crlf = '\r\n' in t
t = t.replace('\r\n', '\n')
L = t.split('\n')

idx = [i for i, l in enumerate(L) if "ta2_de = 1'b0;" in l]
if len(idx) != 1:
    raise SystemExit('ta2_de 锚点 %d 处' % len(idx))
i = idx[0]
assert 'repeat(2) @(posedge clk);' in L[i + 1], L[i + 1]
L[i + 1] = ("        @(posedge clk);       // 像素在这个正沿被采样（读出 + 判据）")
assert 'negedge clk' in L[i + 2], L[i + 2]
L[i + 2] = ("        @(negedge clk);       // 半个周期后读结果，避开与正沿的竞争")
t = '\n'.join(L)
print('[ok]   ta2_px 采样时刻改为「正沿后半个周期」')

#  补一条「写回真的落盘」的检查
anchor = [i for i, l in enumerate(L) if 'chk("tacc_noise_x"' in l]
if len(anchor) != 1:
    raise SystemExit('tacc_noise_x 锚点 %d 处' % len(anchor))
extra = ("    //  再补一帧（(2,1) 第 3 次命中）：说明上一步「不亮」真的写回内存了\n"
         "    ta2_px(3'd2, 3'd1, 1'b1);\n"
         "    chk(\"tacc_persist\", {31'b0, ta2_masko}, 32'd1);\n")
L = t.split('\n')
L.insert(anchor[0] + 1, extra.rstrip('\n'))
t = '\n'.join(L)
print('[ok]   增加 tacc_persist 检查')

out = t.replace('\n', '\r\n') if crlf else t
with open(p, 'wb') as fh:
    fh.write(out.encode('gbk'))
with open(p, 'rb') as fh:
    if fh.read().decode('gbk') != out:
        raise SystemExit('**** tb 回读比对失败 ****')
print('[ok]   sim/tb_armor_vision.v  %d -> %d bytes' % (len(raw), len(out.encode('gbk'))))
print('=== P12 修补 2 完成 ===')
