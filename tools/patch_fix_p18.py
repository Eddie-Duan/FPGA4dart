# -*- coding: utf-8 -*-
"""
patch_fix_p18.py -- 收尾修 4 处问题（含 2 个真 bug）

1) rtl/ov5640_lcd.v  —— 我上一个补丁的锚点没带行尾注释，导致 sys_rst_n 的注释
   被挤到 uart_txd 那行。改掉（代码本身没错，只是注释错位）。
2) rtl/vision_stat.v —— frame_cyc 差一：cyc_cnt 在两个 vsync 上升沿之间只数到
   (周期-1)，所以 800x480 时报 554399 而不是 554400。锁存时 +1。
3) rtl/track_ab.v   —— **真 bug**：首次捕获时 α-β 把「从 0 到目标的整段距离」
   当成速度（v = BETA*400 = 100），下一帧预测位置直接冲到 300，真正的目标 400
   反而落在门控半径(96)外被拒掉 -> valid 永远建立不起来。
   实测 track_ab 单元测试 6 项全挂就是这个原因。改成首次捕获直接定位、速度归零。
4) sim/tb_armor_vision.v —— phase 5 的 aim_y 还是精确比较。团块跟踪现在报真实外延
   （宽 199 -> 201），aim_y = 248 - 201*64/256 = 198 而不是 199，这是定义变化不是错误，
   改成 chk_near ±2（phase 1/2 已经改过了）。
5) doc/vision_pipeline.md —— 那句话说 uart 故意没接引脚，现在接了 U5/T6，要更新。

安全性：GBK/UTF-8 各自按原编码读写，写回前回读比对。可重复执行。
用法：python tools/patch_fix_p18.py
"""

import os

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)


def decode_any(raw, rel):
    """GBK / UTF-8 自动识别。工程要求 .v 是 GBK，但编辑器有时会把它存回 UTF-8，
    所以这里都不假设，读进来统一再写成 GBK。"""
    for enc in ('gbk', 'utf-8'):
        try:
            return raw.decode(enc), enc
        except UnicodeDecodeError:
            continue
    raise SystemExit('%s 既不是 GBK 也不是 UTF-8，放弃' % rel)


def edit(rel, out_enc, pairs, skip_token=None):
    path = os.path.join(ROOT, rel.replace('/', os.sep))
    with open(path, 'rb') as fh:
        raw = fh.read()
    text, in_enc = decode_any(raw, rel)
    if in_enc != out_enc:
        print('[enc]  %s 是 %s，将改写为 %s' % (rel, in_enc, out_enc))
    crlf = '\r\n' in text
    norm = text.replace('\r\n', '\n')

    if skip_token and skip_token in norm:
        print('[skip] %s 已经处理过' % rel)
        return

    for old, new in pairs:
        old = old.replace('\r\n', '\n')
        new = new.replace('\r\n', '\n')
        if norm.count(old) != 1:
            raise SystemExit('%s: 锚点匹配 %d 处（应为 1）:\n%s'
                             % (rel, norm.count(old), old[:160]))
        norm = norm.replace(old, new)

    out_text = norm.replace('\n', '\r\n') if crlf else norm
    out = out_text.encode(out_enc)
    with open(path, 'wb') as fh:
        fh.write(out)
    with open(path, 'rb') as fh:
        if fh.read().decode(out_enc) != out_text:
            raise SystemExit('**** %s 回读比对失败 ****' % rel)
    print('[ok]   %s  %d -> %d bytes' % (rel, len(raw), len(out)))


# ---------------------------------------------------------------------------
# 1) ov5640_lcd.v 注释错位（按行处理，因为要动的就是行尾）
# ---------------------------------------------------------------------------
def fix_comment():
    rel = 'rtl/ov5640_lcd.v'
    path = os.path.join(ROOT, rel.replace('/', os.sep))
    with open(path, 'rb') as fh:
        raw = fh.read()
    text = raw.decode('gbk')
    crlf = '\r\n' in text
    lines = text.replace('\r\n', '\n').split('\n')

    if any('//系统复位' in l and l.lstrip().startswith('input') and 'sys_rst_n' in l
           for l in lines):
        print('[skip] rtl/ov5640_lcd.v 注释已经是对的')
        return

    fixed = 0
    for i, l in enumerate(lines):
        if 'uart_txd' in l and 'PC）' in l:
            j = l.find('PC）')
            lines[i] = l[:j + 3]
            fixed += 1
        elif l.lstrip().startswith('input') and 'sys_rst_n' in l:
            lines[i] = '    input                 sys_rst_n    ,  //系统复位，低电平有效'
            fixed += 1
    if fixed == 0:
        raise SystemExit('找不到要修的行')

    out_text = '\n'.join(lines)
    if crlf:
        out_text = out_text.replace('\n', '\r\n')
    with open(path, 'wb') as fh:
        fh.write(out_text.encode('gbk'))
    with open(path, 'rb') as fh:
        if fh.read().decode('gbk') != out_text:
            raise SystemExit('**** 回读比对失败 ****')
    print('[ok]   rtl/ov5640_lcd.v  注释归位（%d 行）' % fixed)


# ---------------------------------------------------------------------------
def main():
    fix_comment()

    edit('rtl/vision_stat.v', 'gbk', [(
        """        // 帧起点：先锁存上一帧的统计量，再清零重新开始
        frame_cyc   <= cyc_cnt;""",
        """        // 帧起点：先锁存上一帧的统计量，再清零重新开始
        //  +1：cyc_cnt 在两个 vsync 上升沿之间只数到 (周期-1)，
        //      不加 1 会差一（800x480 时报 554399 而不是 554400）
        frame_cyc   <= cyc_cnt + 32'd1;""")],
        skip_token='cyc_cnt + 32\'d1')

    edit('rtl/track_ab.v', 'gbk', [(
        """            px  <= npx;
            py  <= npy;
            vx  <= nvx;
            vy  <= nvy;
            cx  <= clampw(nx);
            cy  <= clamph(ny);
            ax  <= clampw(nx);
            ay  <= clamph(ny - aim_off);
            aim_off <= $signed({1'b0, raw_cy}) - $signed({1'b0, raw_ay});""",
        """            //  首次捕获（之前没在跟踪）：位置直接取测量值、速度归零。
            //  否则 alpha-beta 会把「从 0 到目标的整段距离」当成速度
            //  （v = BETA*400 = 100），下一帧预测位置直接冲到 300，
            //  真正的目标 400 反倒落在门控半径(96)之外被拒掉，
            //  valid 就永远建立不起来 —— 单元测试 6 项全挂就是这个原因。
            if(!tracking) begin
                px <= $signed({1'b0, raw_cx});
                py <= $signed({1'b0, raw_cy});
                vx <= 0;
                vy <= 0;
                cx <= raw_cx;
                cy <= raw_cy;
                ax <= raw_cx;
                ay <= raw_ay;
            end
            else begin
                px  <= npx;
                py  <= npy;
                vx  <= nvx;
                vy  <= nvy;
                cx  <= clampw(nx);
                cy  <= clamph(ny);
                ax  <= clampw(nx);
                ay  <= clamph(ny - aim_off);
            end
            aim_off <= $signed({1'b0, raw_cy}) - $signed({1'b0, raw_ay});""")],
        skip_token='if(!tracking) begin')

    edit('sim/tb_armor_vision.v', 'gbk', [(
        """    chk("th_gr",      u_armor_vision.th_gr, 32'd32);
    chk("bond_valid", bond_valid          , 32'd1 );
    chk("center_x",   center_x            , EXP_CX);
    chk("aim_y",      aim_y               , EXP_AY);""",
        """    chk("th_gr",      u_armor_vision.th_gr, 32'd32);
    chk("bond_valid", bond_valid          , 32'd1 );
    chk("center_x",   center_x            , EXP_CX);
    //  团块跟踪报真实外延 -> 宽 201（旧投影被 TH_MIN=4 裁到 199）
    //  -> aim_y = 248 - 201*64/256 = 198，差 1 像素是定义变化，放宽容差
    chk_near("aim_y",   aim_y             , EXP_AY  , 32'd2);""")],
        skip_token='chk_near("aim_y",   aim_y             , EXP_AY  , 32\'d2)')

    edit('doc/vision_pipeline.md', 'utf-8', [(
        """    > 注意：目前 `uart_txd` 在 `ov5640_lcd.v` 裡**故意沒有接引腳**（板上 USB-UART 的引腳要按
    > 實際接線再定；現在加頂層埠 + 未約束 IO 只會變成一堆 unconstrained IO 的麻煩）。
    > 要用起來：在 `pin.xdc` 裡約束，再把這兩根線引到頂層。""",
        """    > **已接好引腳**：`uart_rxd` = **U5**（input）、`uart_txd` = **T6**（output），
    > 電平 LVCMOS33，取自《達芬奇開發板IO引腳分配表》，已在 `pin.xdc` 裡約束。
    > （表上另有 `uart2_txd`=R19 / `uart2_rxd`=P19，那是 ATK 模組介面，未使用。）
    >
    > PC 端解析：`python tools/uart_parse.py COM3`（需要 pyserial），
    > 離線解析：`python tools/uart_parse.py --hex "A5 5A ..."`，
    > 下發參數：`python tools/uart_parse.py COM3 --set 0x07 0x01`。""")],
        skip_token='已接好引腳')

    print('done.')


if __name__ == '__main__':
    main()
