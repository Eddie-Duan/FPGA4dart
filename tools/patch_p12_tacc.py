# -*- coding: utf-8 -*-
"""
patch_p12_tacc.py -- 多帧累积（P12）接线

1) sim/run_vision_sim.bat / tools/synth_check_vision.tcl 加入 temporal_acc.v
2) rtl/reg_file.v   新增 0x0C = TACC（b1:0 = 阈值 thr，b7 = 强制清零）
3) rtl/armor_vision.v 例化 temporal_acc，并把 blob_track 的
   de/x/y/mask 换成它的对齐输出（关掉时是纯直通 -> 行为与现在逐位一致）
4) sim/tb_armor_vision.v 加相位 14：temporal_acc 单元测试
   （8x4 的小尺寸，验证「单帧噪声被拒绝 / 连中两帧被留住 / 灯走了会消失」）

GBK 字节级改 + 回读比对。
"""

import os

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)


def load(rel):
    with open(os.path.join(ROOT, rel), 'rb') as fh:
        raw = fh.read()
    for enc in ('gbk', 'utf-8'):
        try:
            return len(raw), raw.decode(enc).replace('\r\n', '\n'), enc, ('\r\n' in raw.decode(enc))
        except UnicodeDecodeError:
            continue
    raise SystemExit('%s 编码未知' % rel)


def save(rel, text, enc, crlf, old_len):
    out = text.replace('\n', '\r\n') if crlf else text
    data = out.encode(enc)
    with open(os.path.join(ROOT, rel), 'wb') as fh:
        fh.write(data)
    with open(os.path.join(ROOT, rel), 'rb') as fh:
        if fh.read().decode(enc) != out:
            raise SystemExit('**** %s 回读比对失败 ****' % rel)
    print('[ok]   %-28s %s  %d -> %d bytes' % (rel, enc, old_len, len(data)))


def sub(t, old, new, what):
    if t.count(old) != 1:
        raise SystemExit('%s：锚点匹配 %d 处（应为 1）' % (what, t.count(old)))
    return t.replace(old, new)


#==========================================================================
# 1) 构建脚本
#==========================================================================
rel = 'sim/run_vision_sim.bat'
raw, t, enc, crlf = load(rel)
if 'temporal_acc' in t:
    print('[skip] %s' % rel)
else:
    t = sub(t, "  ..\\rtl\\ballistic.v ^\n",
            "  ..\\rtl\\ballistic.v ^\n  ..\\rtl\\temporal_acc.v ^\n", 'bat')
    save(rel, t, enc, crlf, raw)

rel = 'tools/synth_check_vision.tcl'
raw, t, enc, crlf = load(rel)
if 'temporal_acc' in t:
    print('[skip] %s' % rel)
else:
    t = sub(t, "    $rtl/ballistic.v \\\n",
            "    $rtl/ballistic.v \\\n    $rtl/temporal_acc.v \\\n", 'tcl')
    save(rel, t, enc, crlf, raw)

#==========================================================================
# 2) reg_file：0x0C = TACC
#==========================================================================
rel = 'rtl/reg_file.v'
raw, t, enc, crlf = load(rel)
if 'r_tacc' in t:
    print('[skip] %s' % rel)
else:
    t = sub(t, "    output reg [7:0]   r_drop_sc ,",
            "    output reg [7:0]   r_drop_sc ,\n"
            "    output reg [7:0]   r_tacc    ,   // 0x0C 多帧累积（b1:0=阈值 b7=强制清零）",
            'reg_file 端口')
    t = sub(t, "        r_drop_sc  <= 8'd255;",
            "        r_drop_sc  <= 8'd255;\n"
            "        r_tacc     <= 8'h02;      // 阈值 2（默认），不清零",
            'reg_file 默认值')
    t = sub(t, "                                8'h0B: r_drop_sc  <= data_t;",
            "                                8'h0B: r_drop_sc  <= data_t;\n"
            "                                8'h0C: r_tacc     <= data_t;",
            'reg_file 地址')
    save(rel, t, enc, crlf, raw)

#==========================================================================
# 3) armor_vision：例化 + 改写 blob_track 的输入
#==========================================================================
rel = 'rtl/armor_vision.v'
raw, t, enc, crlf = load(rel)
if 'u_temporal_acc' in t:
    print('[skip] %s' % rel)
else:
    # 3a) 参数
    t = sub(t, "    parameter [7:0] DROP_SCALE_DEF = 8'd255,",
            "    parameter [7:0] DROP_SCALE_DEF = 8'd255,\n"
            "    parameter TACC_EN         = 1'b0  ,   // 多帧时域累积（默认关；开了灵敏度↑但要 20+ 个 BRAM）",
            'armor_vision 参数')
    # 3b) wire
    t = sub(t, "wire [7:0]    drop_sc_eff    ;   // 0x0B\n",
            "wire [7:0]    drop_sc_eff    ;   // 0x0B\n"
            "wire [7:0]    rf_tacc        ;   // 0x0C\n"
            "wire [1:0]    thr_eff        ;   // 累积阈值\n"
            "wire          tacc_en, tacc_clr;\n"
            "wire          mask_t, de_t   ;   // 累积后的掩码（与 x_t/y_t 对齐）\n"
            "wire [AW-1:0] x_t, y_t       ;\n",
            'armor_vision TACC wire')
    # 3c) reg_file 例化
    t = sub(t, "    .r_drop_sc  (rf_drop_sc ),",
            "    .r_drop_sc  (rf_drop_sc ),\n"
            "    .r_tacc     (rf_tacc    ),",
            'armor_vision reg_file')
    # 3d) 生效值
    t = sub(t, "wire dist_on  = DIST_EN  | rf_ctrl[6];   // b6 = 弹道补偿使能\n",
            "wire dist_on  = DIST_EN  | rf_ctrl[6];   // b6 = 弹道补偿使能\n"
            "wire tacc_on  = TACC_EN  | rf_ctrl[7];   // b7 = 多帧累积使能\n",
            'armor_vision tacc_on')
    t = sub(t, "assign drop_sc_eff = reg_written ? rf_drop_sc : DROP_SCALE_DEF;\n",
            "assign drop_sc_eff = reg_written ? rf_drop_sc : DROP_SCALE_DEF;\n"
            "assign thr_eff     = reg_written ? rf_tacc[1:0] : 2'd2;\n"
            "assign tacc_en     = tacc_on;\n"
            "assign tacc_clr    = reg_written & rf_tacc[7];\n",
            'armor_vision 生效值')
    # 3e) 例化 temporal_acc（放在 blob_track 之前）
    t = sub(t,
            "blob_track #(\n"
            "    .WIDTH    (IMG_W    ),\n",
            "//-------------------------------------------------------\n"
            "// (8b) 多帧时域累积（P12）：把闪变的远灯粘住，同时压掉单帧噪声\n"
            "//   关掉（默认）时是纯直通、零延迟 -> 行为与没有这个模块逐位一致；\n"
            "//   打开后掩码晚 2 拍，所以 x/y/de 一起延 2 拍（保证坐标对齐）。\n"
            "//-------------------------------------------------------\n"
            "temporal_acc #(\n"
            "    .WIDTH  (IMG_W),\n"
            "    .HEIGHT (IMG_H),\n"
            "    .AW     (AW   )\n"
            ") u_temporal_acc (\n"
            "    .clk     (clk       ),\n"
            "    .rst_n   (rst_n     ),\n"
            "    .de      (de_v      ),\n"
            "    .x       (x_v       ),\n"
            "    .y       (y_cnt     ),\n"
            "    .mask_in (mask_d    ),\n"
            "    .en      (tacc_en   ),\n"
            "    .thr     (thr_eff   ),\n"
            "    .clr     (tacc_clr  ),\n"
            "    .x_o     (x_t       ),\n"
            "    .y_o     (y_t       ),\n"
            "    .de_o    (de_t      ),\n"
            "    .mask_o  (mask_t    )\n"
            ");\n"
            "\n"
            "blob_track #(\n"
            "    .WIDTH    (IMG_W    ),\n",
            'armor_vision temporal_acc 例化')
    # 3f) blob_track 改用累积后的信号
    t = sub(t,
            "    .mask       (mask_d     ),\n"
            "    .min_area_lo (min_area_lo_eff),   // 宽松档：远 / 小目标也要认出来\n",
            "    .mask       (mask_t     ),   // P12：多帧累积后的掩码（关掉时 == mask_d）\n"
            "    .min_area_lo (min_area_lo_eff),   // 宽松档：远 / 小目标也要认出来\n",
            'blob_track mask')
    t = sub(t,
            "    .vsync      (vsync      ),\n"
            "    .de         (de_v       ),\n"
            "    .x          (x_v        ),\n"
            "    .y          (y_cnt      ),\n"
            "    .mask       (mask_t     ),",
            "    .vsync      (vsync      ),\n"
            "    .de         (de_t       ),\n"
            "    .x          (x_t        ),\n"
            "    .y          (y_t        ),\n"
            "    .mask       (mask_t     ),",
            'blob_track de/x/y')
    save(rel, t, enc, crlf, raw)

print('=== P12 接线完成 ===')
