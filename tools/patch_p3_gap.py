# -*- coding: utf-8 -*-
"""
patch_p3_gap.py -- 修 blob_track 的「反光白带把灯切成上下两块」回归

现象（phase 2 眩光相位）：
    bond_t = 148 ✓   bond_b = 232 ✗ (期望 348)
    center_y = 190 ✗ (期望 248)     aim_y = 141 ✗
    即：只认出上半盏灯。

原因：
    白带（py 225..255）在图上没有绿色，所以那 31 行一个 emit 都没有。
    而原来的匹配条件是「记录最后更新行 == 当前行 或 == 当前行-1」——
    下半个灯回来时（第 256 行）记录的 r_row 还停在 224，相差 32 行，匹配不上，
    于是新开了一个记录。帧末取「面积最大者」，上下两块面积接近，就只拿到了上半块。

    讽刺的是：旧 proj_bond 取整帧直方图外沿，反而不会被这种「横向白带」切开，
    所以这个相位之前是过的 —— 我这次换团块跟踪把它弄回归了。

修法：
    把「紧邻上一行」放宽成「纵向间隙 <= GAP_MAX」。
    GAP_MAX 默认 64 行（白带是 31 行，余量充足）。
    代价：纵向相距小于 GAP_MAX 且水平区间重叠的两个物体也会并成一个
    —— 对「一个大的灯」这种靶标无所谓；真要严格区分多目标，把 GAP_MAX 调小即可。

安全性：GBK 解码 -> 纯 ASCII 锚点替换 -> GBK 编码 -> 回读比对。可重复执行。
用法：python tools/patch_p3_gap.py
"""

import os

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
TARGET = os.path.join(ROOT, 'rtl', 'blob_track.v')

OLD_PARAM = """    parameter MIN_AREA = 400        ,   // 低于这个面积不算目标
    parameter AIM_H_Q8 = 8'd64          // 瞄准点偏移 = 宽度 x AIM_H_Q8/256"""

NEW_PARAM = """    parameter MIN_AREA = 400        ,   // 低于这个面积不算目标
    parameter GAP_MAX  = 64         ,   // 允许的纵向间隙（行）；反光白带把灯切成上下
                                        // 两块时靠它把两块并回一个团块。调小 = 更严格地区分
                                        // 上下相邻的多个目标
    parameter AIM_H_Q8 = 8'd64          // 瞄准点偏移 = 宽度 x AIM_H_Q8/256"""

OLD_MATCH = """    assign match[gv] = r_used[gv]
                    && ((r_row[gv] == emit_y) || ((emit_y != 0) && (r_row[gv] == q_ym1)))
                    && (r_l[gv] <= emit_x1) && (emit_x0 <= r_r[gv]);"""

NEW_MATCH = """    //  放宽成「纵向间隙 <= GAP_MAX」而不是「紧邻上一行」：
    //  镜面反光在灯上打出的白色横带会让那几行完全没有绿色，上下两块在图上并不相邻。
    //  只认紧邻的话，上下两块会变成两个团块，帧末取面积最大者 -> 只剩半盏灯
    //  （实测 center_y 从 248 掉到 190，就是把旧 proj_bond 的优点弄丢了）。
    //  emit_y >= r_row 保证不会往下匹配到未来行；差值用 AW+1 位不会借位。
    assign match[gv] = r_used[gv]
                    && (emit_y >= r_row[gv])
                    && (({1'b0, emit_y} - {1'b0, r_row[gv]}) <= GAP_MAX)
                    && (r_l[gv] <= emit_x1) && (emit_x0 <= r_r[gv]);"""


def main():
    with open(TARGET, 'rb') as fh:
        raw = fh.read()
    text = raw.decode('gbk')
    crlf = '\r\n' in text
    norm = text.replace('\r\n', '\n')

    if 'GAP_MAX' in norm:
        print('[skip] rtl/blob_track.v 已经改过')
        return

    for old, new in ((OLD_PARAM, NEW_PARAM), (OLD_MATCH, NEW_MATCH)):
        if norm.count(old) != 1:
            raise SystemExit('锚点匹配 %d 处（应为 1）：\n%s' % (norm.count(old), old[:160]))
        norm = norm.replace(old, new)

    out_text = norm.replace('\n', '\r\n') if crlf else norm
    out = out_text.encode('gbk')
    with open(TARGET, 'wb') as fh:
        fh.write(out)
    with open(TARGET, 'rb') as fh:
        if fh.read().decode('gbk') != out_text:
            raise SystemExit('**** 回读比对失败 ****')

    print('[ok]   rtl/blob_track.v  GBK %d -> %d bytes' % (len(raw), len(out)))
    print('       匹配条件: 紧邻上一行 -> 纵向间隙 <= GAP_MAX(64)')


if __name__ == '__main__':
    main()
