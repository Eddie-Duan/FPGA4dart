# -*- coding: utf-8 -*-
"""
patch_camera_lock.py -- 可选的「固定曝光 / 固定增益」（防镜面反光）

【背景：为什么改成「默认关闭」】
    LCD 面板有光泽，房间灯按镜面反射射进镜头时会：
      - 抬高整帧平均亮度 -> AEC 缩短曝光 -> **全画面一起变暗**
      - 反射光是白的   -> AWB 推白平衡   -> **绿色判据的差值整体缩小**
    于是「局部一小块眩光」被负反馈放大成「整个目标消失」。dart 工程的相机就是固定曝光
    （io/hikrobot/hikrobot.cpp: ExposureAuto=OFF / GainAuto=OFF）。

    ⚠️ 但**固定曝光必须按现场亮度标定**。第一版直接把曝光写死成 0x0200 且默认启用，
    如果这个值对现场来说太小，传感器输出的就是一帧接近全黑的画面 ——
    而 lcd_driver 里 `assign lcd_bl = 1'b1`（背光是常亮的），
    所以现象就是「背光亮着但屏幕全黑」，很像「屏坏了/连不上」。
    （实测就是这样翻车的：刷完新 bitstream 后屏全黑。）

    ⚠️ 第一版还写了 AWB 手动增益 0x3400/0x3401 = 0x01/0x00（想表示 1x）。
    但 OV5640 这个寄存器到底是 [9:8] 还是 [11:8] 我没有权威依据（10bit 装不下 0x400，
    所以更可能是 [11:8]，1x 要写 0x04）。写错的后果同样是画面异常。
    -> 这一版**完全不碰 AWB**（0x3406 保持自动），把不确定的东西全部拿掉。

【现在做什么】
    在寄存器表尾补 6 条（索引 250~255）：
        0x3503 = CAM_LOCK_EN ? 0x03 : 0x00    AEC/AGC 手动（关 = 保持原厂自动）
        0x3500/01/02                          手动曝光（20bit）
        0x350a/0b                             手动增益（10bit，0x010 = 1x）
    并把 REG_NUM 从 8'd250 改成 9'd256、init_reg_cnt 从 [7:0] 加宽到 [8:0]
    （8bit 装不下 256，会溢出回绕导致初始化跑不完）。

    ★ 默认 CAM_LOCK_EN = 1'b0，也就是**行为和原厂例程完全一致**，屏幕一定是好的。
    ★ 想启用：把 CAM_LOCK_EN 改成 1'b1，然后按现场亮度调 EXP_15_8
      （暗了就加大、过曝就减小；大致 0x0100 很暗 ~ 0x2000 很亮）。
    ★ 抗反光的**算法**那半（color_seg 的相对饱和度闸 + proj_bond 取外沿）不依赖这里，
      默认就是开着的，所以即使不动相机也有基本防护。

【编码】文件是 GBK。本脚本 GBK 解码 -> 改 -> GBK 编码写回，并做往返比对。
        如果检测到第一版的坏补丁（写了 0x3406/0x3400…），会先从 _backup_before_green 还原。

用法：
    python tools/patch_camera_lock.py
"""

import os
import re
import shutil

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
TARGET = os.path.join(ROOT, 'rtl', 'i2c_ov5640_rgb565_cfg.v')
BACKUP = os.path.join(ROOT, '_backup_before_green', 'rtl', 'i2c_ov5640_rgb565_cfg.v')

ANCHOR_249 = "8'd249: i2c_data <= {16'h3019,8'h00};"

PARAMS = """
//----------------------------------------------------------------------------------------
// 相机固定曝光 / 增益（防镜面反光，可选）  —— 详见 tools/patch_camera_lock.py 的说明
//
//   CAM_LOCK_EN = 1'b0 : 保持原厂的自动曝光 / 自动增益，屏幕一定是好的（默认）
//   CAM_LOCK_EN = 1'b1 : 用手动的 EXP_* / GAIN_* —— 需要按现场亮度标定！
//
//   注意：标定方法：上电看 LCD。画面太暗就把 EXP_15_8 调大（0x01 -> 0x02 -> 0x04 -> 0x08…），
//      过曝发白就调小。大致范围：0x0100（很暗）~ 0x2000（很亮）。
//   注意：本脚本不写 AWB 寄存器（0x3406 保持自动），避免白平衡增益写错导致画面异常。
//----------------------------------------------------------------------------------------
localparam        CAM_LOCK_EN = 1'b0;
localparam [7:0]  EXP_19_16   = 8'h00;   // 曝光 [19:16]
localparam [7:0]  EXP_15_8    = 8'h08;   // 曝光 [15:8]  -> 默认 0x0800
localparam [7:0]  EXP_7_0     = 8'h00;   // 曝光 [7:0]
localparam [7:0]  GAIN_9_8    = 8'h00;   // 增益 [9:8]
localparam [7:0]  GAIN_7_0    = 8'h10;   // 增益 [7:0]   -> 0x010 = 1x
"""

LOCK_REGS = """            //=== 相机固定曝光 / 增益（可选，默认关闭）===
            // 反射光进画面会让 AEC 缩曝光、AWB 推白平衡，把整幅画面的亮度/色彩一起拉走，
            // 绿色判据的固定阈值就失守。这里在需要时把曝光/增益锁死。
            // CAM_LOCK_EN = 1'b0 时写 0x3503 = 0x00，等于什么都没改。
            9'd250: i2c_data <= {16'h3503,CAM_LOCK_EN ? 8'h03 : 8'h00}; //AEC/AGC 手动
            9'd251: i2c_data <= {16'h3500,EXP_19_16}; //曝光[19:16]
            9'd252: i2c_data <= {16'h3501,EXP_15_8 }; //曝光[15:8]
            9'd253: i2c_data <= {16'h3502,EXP_7_0  }; //曝光[7:0]
            9'd254: i2c_data <= {16'h350a,GAIN_9_8 }; //增益[9:8]
            9'd255: i2c_data <= {16'h350b,GAIN_7_0 }; //增益[7:0]
"""


def revert_if_needed(text):
    """
    如果文件里是第一版的坏补丁（把 AWB 也锁成手动），先还原成原厂版本。

    只认真正的寄存器表行（i2c_data <= {16'h3400..3406}），不认注释里出现的数字 ——
    否则本脚本自己加的说明文字（里面提到 0x3406）会把自己误判成旧补丁，每次重跑都白还原一次。
    """
    if not re.search(r"i2c_data\s*<=\s*\{\s*16'h340[0-6]", text):
        return text, False
    if not os.path.isfile(BACKUP):
        raise SystemExit('检测到第一版补丁但没有备份档可还原，请手动处理')
    shutil.copyfile(BACKUP, TARGET)
    print('[ok]   检测到第一版补丁（写了 AWB 寄存器），已从 _backup_before_green 还原')
    return open(TARGET, 'rb').read().decode('gbk'), True


def edit(text):
    if 'CAM_LOCK_EN' in text:
        return text, 'skip'

    old = "localparam  REG_NUM = 8'd250"
    if text.count(old) != 1:
        raise SystemExit('找不到 REG_NUM 定义')
    text = text.replace(old, "localparam  REG_NUM = 9'd256")

    old = "reg    [7:0]   init_reg_cnt"
    if text.count(old) != 1:
        raise SystemExit('找不到 init_reg_cnt 定义')
    text = text.replace(old, "reg    [8:0]   init_reg_cnt")

    nl = '\r\n' if '\r\n' in text else '\n'

    i = text.index("localparam  REG_NUM = 9'd256")
    j = text.index(nl, i) + len(nl)
    text = text[:j] + PARAMS.replace('\n', nl) + text[j:]

    i = text.index(ANCHOR_249)
    j = text.index(nl, i) + len(nl)
    text = text[:j] + LOCK_REGS.replace('\n', nl) + text[j:]

    return text, 'ok'


def main():
    raw = open(TARGET, 'rb').read()
    text = raw.decode('gbk')

    #  已经是当前版本 -> 直接跳过（幂等）
    if 'CAM_LOCK_EN' in text:
        print('[skip] rtl/i2c_ov5640_rgb565_cfg.v 已经是当前版本')
        return

    text, reverted = revert_if_needed(text)
    if reverted:
        raw = open(TARGET, 'rb').read()

    new, status = edit(text)
    if status == 'skip':
        print('[skip] rtl/i2c_ov5640_rgb565_cfg.v 已经是当前版本')
        return

    out = new.encode('gbk')
    open(TARGET, 'wb').write(out)
    if open(TARGET, 'rb').read().decode('gbk') != new:
        raise SystemExit('**** 转换后比对失败，请从 _backup_before_green 还原 ****')

    print('[ok]   rtl/i2c_ov5640_rgb565_cfg.v  GBK %d -> %d bytes' % (len(raw), len(out)))
    print('       新增索引 250~255（0x3503 + 曝光 x3 + 增益 x2），REG_NUM 8\'d250 -> 9\'d256')
    print('       CAM_LOCK_EN 默认 1\'b0 = 保持原厂自动曝光，屏幕一定是好的')


if __name__ == '__main__':
    main()
