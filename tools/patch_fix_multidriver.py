# -*- coding: utf-8 -*-
"""
patch_fix_multidriver.py -- 修 osd_text.v 的 conv_done 多驱动

问题（Vivado 综合/实现报的，仿真抓不到）：
    conv_done 在**两个** always 块里被赋值：
      - 转换状态机块：CV_IDLE 清 0、CV_SAVE 置 1
      - 数字刷新块：用完清 0
    -> 多驱动网络：
         [Synth 8-6859] multi-driven net on pin .../hgb[255][19]   （chroma_hist 那边）
         [DRC MDRV-1] Multiple Driver Nets: Net .../Q[0] has multiple drivers
       xsim 容忍（自己挑一个驱动），Vivado 直接拒绝，Opt_design 根本跑不起来。

修法：
    只让**状态机块**驱动 conv_done，并把它变成干净的单拍脉冲
        conv_done <= (cv_state == CV_SAVE) && (cv_sel == 2'd3);
    刷新块只读不写。

为什么用 ASCII 锚点：这个文件的中文注释被编辑器二次编码成了乱码（U+FFFD），
任何带中文的锚点都不可靠；纯 ASCII 锚点在 UTF-8/GBK 下都一样。

用法：python tools/patch_fix_multidriver.py
"""
import os

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
TARGET = os.path.join(ROOT, 'rtl', 'osd_text.v')


def decode_any(raw, rel):
    for enc in ('gbk', 'utf-8'):
        try:
            return raw.decode(enc), enc
        except UnicodeDecodeError:
            continue
    raise SystemExit('%s 既不是 GBK 也不是 UTF-8' % rel)


PAIRS = [
    #  1) 在状态机块开头加单拍脉冲赋值
    ("""    else begin
        case(cv_state)
            CV_IDLE: begin
                if(vsync_rise) begin""",
     """    else begin
        //  conv_done = 「本拍刚好把第 4 个数存完」的单拍脉冲。
        //  只允许这一个 always 块驱动它 —— 另一个块只读不写，
        //  否则会成为多驱动网络，Vivado 报 [DRC MDRV-1]，Opt_design 跑不起来。
        conv_done <= (cv_state == CV_SAVE) && (cv_sel == 2'd3);

        case(cv_state)
            CV_IDLE: begin
                if(vsync_rise) begin"""),

    #  2) CV_IDLE 里删掉重复赋值
    ("""                    cv_it    <= 5'd0;
                    conv_done<= 1'b0;
                    cv_state <= CV_LOOP;""",
     """                    cv_it    <= 5'd0;
                    cv_state <= CV_LOOP;"""),

    #  3) CV_SAVE 里删掉重复赋值
    ("""                if(cv_sel == 2'd3) begin
                    conv_done <= 1'b1;
                    cv_state  <= CV_IDLE;
                end""",
     """                if(cv_sel == 2'd3) begin
                    cv_state <= CV_IDLE;
                end"""),

    #  4) 刷新块里删掉写入（只读）
    ("""    else if(conv_done) begin""",
     """    else if(conv_done) begin      // 只读 conv_done，不写 -> 保持单驱动"""),
]

#  刷新块里那行 `conv_done <= 1'b0;` 要删掉。
#  注意：状态机块的**复位分支**里也有一行一模一样的（8 空格缩进），所以要带上后一行才唯一。
DEL_OLD = "        conv_done <= 1'b0;\n        nd0 <= ndig(b0_bcd);"
DEL_NEW = "        nd0 <= ndig(b0_bcd);"


def main():
    with open(TARGET, 'rb') as fh:
        raw = fh.read()
    text, enc = decode_any(raw, 'rtl/osd_text.v')
    crlf = '\r\n' in text
    norm = text.replace('\r\n', '\n')

    if '保持单驱动' in norm:
        print('[skip] rtl/osd_text.v 已经改过')
        return

    for old, new in PAIRS:
        if norm.count(old) != 1:
            raise SystemExit('锚点匹配 %d 处（应为 1）:\n%s' % (norm.count(old), old[:200]))
        norm = norm.replace(old, new)

    if norm.count(DEL_OLD) != 1:
        raise SystemExit('要删的那段匹配 %d 处（应为 1）' % norm.count(DEL_OLD))
    norm = norm.replace(DEL_OLD, DEL_NEW)

    #  统计一下还有几处 conv_done 的写入，确认只剩状态机块那一处
    n_assign = norm.count('conv_done <=')
    out_text = norm.replace('\n', '\r\n') if crlf else norm
    with open(TARGET, 'wb') as fh:
        fh.write(out_text.encode(enc))
    with open(TARGET, 'rb') as fh:
        if fh.read().decode(enc) != out_text:
            raise SystemExit('**** 回读比对失败 ****')

    print('[ok]   rtl/osd_text.v  (%s)  %d -> %d bytes' % (enc, len(raw), len(out_text.encode(enc))))
    print('       conv_done 现在只剩 %d 处赋值（应全部在状态机块内）' % n_assign)


if __name__ == '__main__':
    main()
