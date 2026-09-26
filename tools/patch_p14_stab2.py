# -*- coding: utf-8 -*-
"""patch_p14_stab2.py -- 续：reg_file 的 0x12 + armor_vision 接线（全 ASCII 前缀锚点）"""
import os

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def load(rel, enc='gbk'):
    with open(os.path.join(ROOT, rel), 'rb') as fh:
        raw = fh.read()
    t = raw.decode(enc)
    return raw, t, ('\r\n' in t), enc


def save(rel, raw, t, crlf, enc='gbk'):
    out = t.replace('\n', '\r\n') if crlf else t
    with open(os.path.join(ROOT, rel), 'wb') as fh:
        fh.write(out.encode(enc))
    with open(os.path.join(ROOT, rel), 'rb') as fh:
        if fh.read().decode(enc) != out:
            raise SystemExit('**** %s 回读比对失败 ****' % rel)
    print('[ok]   %s  %d -> %d bytes' % (rel, len(raw), len(out.encode(enc))))


def sub(t, old, new, what):
    if t.count(old) != 1:
        raise SystemExit('%s：锚点 %d 处' % (what, t.count(old)))
    print('[ok]   %s' % what)
    return t.replace(old, new)


# ---------------- reg_file.v (UTF-8) ----------------
rel = 'rtl/reg_file.v'
raw, t, crlf, enc = load(rel, 'utf-8')
t = t.replace('\r\n', '\n')
if 'r_flags2' in t:
    print('[skip] reg_file 已有 r_flags2')
else:
    t = sub(t, "    output reg [7:0]   r_lead_auto,",
            "    output reg [7:0]   r_flags2   ,  // 0x12 P14 b0 = 强制打开 α-β 跟踪器\n"
            "    output reg [7:0]   r_lead_auto,",
            'reg_file: r_flags2 端口')
    t = sub(t, "        r_lead_auto<= 8'd1;",
            "        r_flags2   <= 8'd0;       // P14：默认不强制开跟踪器\n"
            "        r_lead_auto<= 8'd1;",
            'reg_file: r_flags2 复位')
    t = sub(t, "                                8'h11: r_lead_auto<= data_t;",
            "                                8'h11: r_lead_auto<= data_t;\n"
            "                                8'h12: r_flags2   <= data_t;",
            'reg_file: 地址 0x12')
    save(rel, raw, t, crlf, enc)

# ---------------- armor_vision.v (GBK) ----------------
rel = 'rtl/armor_vision.v'
raw, t, crlf, enc = load(rel)
t = t.replace('\r\n', '\n')

if 'rf_flags2' not in t:
    t = sub(t, "wire [7:0]    rf_syn_spd, rf_syn_r, rf_syn_en, rf_st_page, rf_lead_auto;\n",
            "wire [7:0]    rf_syn_spd, rf_syn_r, rf_syn_en, rf_st_page, rf_lead_auto, rf_flags2;\n"
            "wire          trk_on   ;   // TRK_EN | 0x12 bit0（运行时强制打开 α-β 跟踪器）\n",
            'armor_vision: flags2 / trk_on wire')
    t = sub(t, "    .r_lead_auto(rf_lead_auto),\n",
            "    .r_lead_auto(rf_lead_auto),\n    .r_flags2   (rf_flags2   ),\n",
            'armor_vision: 接 r_flags2')
    # trk_on 定义放在 tacc_on 那一片
    t = sub(t, "wire tacc_on  = TACC_EN  | rf_ctrl[7];",
            "wire tacc_on  = TACC_EN  | rf_ctrl[7];\n"
            "wire trk_on   = TRK_EN   | rf_flags2[0];  // P14：0x12 bit0 可在运行中打开 α-β 跟踪器",
            'armor_vision: trk_on 定义')
    # 三处 TRK_EN 选择器改成 trk_on（跟踪器可在运行时打开/关闭）
    t = sub(t, "    .raw_valid (TRK_EN ? trk_valid : raw_valid),\n"
               "    .cx        (TRK_EN ? trk_cx    : raw_cx   ),\n"
               "    .cy        (TRK_EN ? trk_cy    : raw_cy   ),\n",
            "    .raw_valid (trk_on ? trk_valid : raw_valid),\n"
            "    .cx        (trk_on ? trk_cx    : raw_cx   ),\n"
            "    .cy        (trk_on ? trk_cy    : raw_cy   ),\n",
            'armor_vision: TRK_EN -> trk_on')
    save(rel, raw, t, crlf, enc)
else:
    print('[skip] armor_vision 已有 rf_flags2')
print('=== P14 续修完成 ===')
