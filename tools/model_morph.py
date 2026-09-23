# -*- coding: utf-8 -*-
"""
model_morph.py -- 视觉管线的 Python 参考模型（设计辅助；不被综合，也不被 xsim 用到）

用途：
    1. 验证「形态学窗口右下角对齐 + 投影」的期望值（309/507/149/347 是怎么来的）
    2. **预测反光（眩光横带）下的行为**，用来比较两种投影策略：
         - 'run'    : 旧版，找 hist 连续 >= 门槛 的**最长区间**
         - 'extent' : 新版，取 hist >= X_MIN_LIT 的**第一个 / 最后一个**位置（区间外沿）
       结论：'run' 会被眩光带切断（高度只剩一半），'extent' 不受影响

模型完全照抄 RTL 的定义：
    seg(x,y)  = 圆内 && 不在眩光带内          （眩光=白，颜色分割判不出绿 -> 洞）
    D(x,y)    = OR  over [x-N+1..x] x [y-N+1..y]
    E(x,y)    = 窗口内 1 的个数 >= K          K = N*N -> 旧版 81-AND 腐蚀
    mask_d    = E & (y_cnt > Y_GUARD)
    hist_x[c] = 列 c 的亮点数（y_cnt 从 1 起算）;  hist_y[r] = 行 r 的亮点数

用法：
    python tools/model_morph.py
"""

import numpy as np

W, H = 800, 480
CX, CY, R = 400, 240, 100     # **原图**坐标下的圆心（测试台就是在 (400,240) 画圆的）
                              # 形态学把它整体往右下平移 N-1=8 -> mask 坐标下是 (408,248)
N = 9
Y_GUARD = 16
TH_MIN = 24
X_MIN_LIT = 4                 # 新版：一列/一行至少亮几个像素才算数


def box_sum(a, n):
    """S[r,c] = a 在窗口 [r-n+1..r] x [c-n+1..c] 内的和（越界按 0）"""
    P = np.zeros((H + 1, W + 1), dtype=np.int32)
    P[1:, 1:] = a.cumsum(0).cumsum(1)
    r = np.arange(H)[:, None]
    c = np.arange(W)[None, :]
    r1, c1 = r + 1, c + 1
    r0 = np.maximum(0, r + 1 - n)
    c0 = np.maximum(0, c + 1 - n)
    return P[r1, c1] - P[r0, c1] - P[r1, c0] + P[r0, c0]


def longest_run(v, thr):
    best, s = None, None
    for i, x in enumerate(v):
        if x >= thr:
            if s is None:
                s = i
        else:
            if s is not None:
                if best is None or (i - s) > (best[1] - best[0] + 1):
                    best = (s, i - 1)
                s = None
    if s is not None and (best is None or (len(v) - s) > (best[1] - best[0] + 1)):
        best = (s, len(v) - 1)
    return best


def first_last(v, thr):
    idx = np.nonzero(v >= thr)[0]
    if len(idx) == 0:
        return None
    return int(idx[0]), int(idx[-1])


def run(mode='extent', k_ero=N * N, glare_cy=None, glare_h=0, blobs=None, quiet=False):
    yy, xx = np.mgrid[0:H, 0:W]
    py = yy + 1                                             # 1..480，和 RTL 的 y_cnt 一致

    if blobs is None:
        disk = ((xx - CX) ** 2 + (py - CY) ** 2) <= R * R
    else:
        # 多个圆（用来验证「两个分开的绿块」会被形状校验挡住）
        disk = np.zeros_like(xx, dtype=bool)
        for (bx, by, br_) in blobs:
            disk |= ((xx - bx) ** 2 + (py - by) ** 2) <= br_ * br_

    if glare_h > 0:
        glare = np.abs(py - glare_cy) <= (glare_h // 2)      # 横贯全宽的眩光带
        seg = disk & ~glare
    else:
        seg = disk

    dil = (box_sum(seg.astype(np.int32), N) > 0).astype(np.int32)
    ero = (box_sum(dil, N) >= k_ero)

    maskd = ero & (py > Y_GUARD)

    hist_x = maskd.sum(axis=0)                               # 索引 = x（0-based，同 x_v）
    hist_y = maskd.sum(axis=1)                               # 索引 = row = py-1

    if mode == 'run':
        tx = max(TH_MIN, hist_x.max() >> 3)
        ty = max(TH_MIN, hist_y.max() >> 3)
        rx, ry = longest_run(hist_x, tx), longest_run(hist_y, ty)
        if rx is None or ry is None:
            if not quiet:
                print('    无目标')
            return None
        bl, br = rx
        bt, bb = ry[0] + 1, ry[1] + 1                        # 换回 RTL 的 y_cnt（1 起算）
    else:
        rx, ry = first_last(hist_x, X_MIN_LIT), first_last(hist_y, X_MIN_LIT)
        if rx is None or ry is None:
            if not quiet:
                print('    无目标')
            return None
        bl, br = rx
        bt, bb = ry[0] + 1, ry[1] + 1

    w, h = br - bl + 1, bb - bt + 1
    xp = hist_x[bl:br + 1].max()

    ok = (w >= 24 and h >= 24 and w <= 2 * h and h <= 2 * w and 2 * xp >= h)
    if not quiet:
        print('    %-6s bl=%3d br=%3d bt=%3d bb=%3d | w=%3d h=%3d | c=(%d,%d) | peak=%3d'
              ' | ok? %s'
              % (mode, bl, br, bt, bb, w, h, (bl + br) >> 1, (bt + bb) >> 1, xp, ok))
    return dict(bl=bl, br=br, bt=bt, bb=bb, w=w, h=h, cx=(bl + br) >> 1, cy=(bt + bb) >> 1,
                ok=ok)


if __name__ == '__main__':
    print('圆：原图坐标 圆心 (%d,%d) 半径 %d ；N=%d  Y_GUARD=%d  TH_MIN=%d  X_MIN_LIT=%d'
          % (CX, CY, R, N, Y_GUARD, TH_MIN, X_MIN_LIT))
    print('（形态学会把二值图整体往右下平移 8 -> mask 坐标下圆心 = (%d,%d)）' % (CX + 8, CY + 8))

    print('-' * 110)
    print('[1] 干净圆（无眩光）—— 两种策略都应该给出 bl=309 br=507 bt=149 bb=347')
    run('run')
    run('extent')

    print('-' * 110)
    print('[2] 横贯眩光带（白色，颜色分割判不出绿 -> 灯条被打一个洞）')
    for gh in (10, 20, 30, 40, 60):
        print('  眩光带高 %d px（位于圆心高度）：' % gh)
        run('run', glare_cy=240, glare_h=gh)
        run('extent', glare_cy=240, glare_h=gh)

    print('-' * 110)
    print('[3] 腐蚀改成多数表决（K = 81-16 = 65, 80%）在眩光下有没有额外好处')
    for gh in (20, 30, 40, 60):
        print('  眩光带高 %d px：' % gh)
        run('extent', k_ero=65, glare_cy=240, glare_h=gh)

    print('-' * 110)
    print('[4] 两颗分开的绿块（各自 40px）—— 形状校验应该把它挡住（ok? False）')
    run('extent', blobs=[(200, 240, 40), (600, 240, 40)])      # 左右分开
    run('extent', blobs=[(400, 120, 40), (400, 380, 40)])      # 上下分开
    run('extent', blobs=[(300, 160, 30), (520, 340, 30)])      # 斜对分开
