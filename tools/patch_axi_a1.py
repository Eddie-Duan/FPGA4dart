# -*- coding: utf-8 -*-
"""
patch_axi_a1.py -- A 线第一阶段：把 AXI4-Lite 结果寄存器接进 Zynq 工程

做三件事（幂等，重复运行不会重复插入）：
  1) rtl/armor_vision.v      : 增加 result_extra[143:0] 与 frame_tick_o 两个输出，
                               并把内部结果打包（不改任何逻辑，只加一根 assign）
  2) rtl/ov5640_lcd_zynq.v   : 增加 S_AXI（AXI4-Lite）与 irq 端口 + 例化 vision_regs_axi
  3) 打印改动点，便于人工复核

编码：rtl/*.v 是 GBK（Vivado 中文 Windows 下按 ANSI 读），脚本按 GBK 读写并回读校验。
"""
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def load(rel):
    p = os.path.join(ROOT, rel)
    return p, open(p, 'rb').read().decode('gbk')


def save(rel, p, text):
    data = text.encode('gbk')
    open(p, 'wb').write(data)
    # 回读校验
    back = open(p, 'rb').read().decode('gbk')
    if back != text:
        sys.exit('ERROR: %s 回读不一致，未写入' % rel)


# ---------------------------------------------------------------- armor_vision
rel = 'rtl/armor_vision.v'
p, s = load(rel)

if 'result_extra' in s:
    print('[skip] %s already patched' % rel)
else:
    m = re.search(r'output\s+\[AW-1:0\]\s+aim_y', s)
    if not m:
        sys.exit('ERROR: %s: 找不到 aim_y 端口' % rel)
    # 最后一个端口补逗号
    s = s[:m.end()] + ',' + s[m.end():]
    # 在端口表结束的 ); 前插入两个新端口
    q = s.index(');', m.end() + 1)
    ins = (
        '    output     [143:0] result_extra ,   // A 线：打包结果给 AXI-Lite\n'
        '    output             frame_tick_o     // A 线：帧末单拍脉冲\n'
    )
    s = s[:q] + ins + s[q:]

    tail = """
//-------------------------------------------------------
// (16) A 线：把结果打包给 AXI-Lite 寄存器文件（PS 侧读取）
//     布局必须与 rtl/ov5640_lcd_zynq.v 的例化保持一致：
//       [10:0] bw      [42:11] area     [58:43] dist_cm  [74:59] drop_px
//       [90:75] vx_q4  [106:91] vy_q4   [116:107] px     [126:117] py
//       [134:127] fill_q8  [137:135] blob_cnt  [143:138] flags
//     纯连线，不参与判决，7A35T 工程不连接这两个输出也不受影响。
//-------------------------------------------------------
assign frame_tick_o = st_frame_tick;
assign result_extra = {
    bond_w_f,                                             // [10:0]
    blob_area,                                            // [42:11]
    bl_dist_cm,                                           // [58:43]
    bl_drop_px,                                           // [74:59]
    pd_vx,                                                // [90:75]
    pd_vy,                                                // [106:91]
    pd_cx,                                                // [116:107]
    pd_cy,                                                // [126:117]
    fill_q8,                                              // [134:127]
    blob_cnt,                                             // [137:135]
    {disp_bin, raw_far, pd_mov, pd_ok, adapt_ok, bl_ok}   // [143:138]
};
"""
    r = s.rfind('endmodule')
    s = s[:r] + tail + '\n' + s[r:]
    save(rel, p, s)
    print('[ok] %s : +result_extra, +frame_tick_o, +pack assign' % rel)

# ------------------------------------------------------------ ov5640_lcd_zynq
rel = 'rtl/ov5640_lcd_zynq.v'
p, s = load(rel)

if 'vision_regs_axi' in s:
    print('[skip] %s already patched' % rel)
else:
    # ---- 1. 端口表：在最后一个端口 m_axi_rready 之后、); 之前插入 S_AXI + irq
    m = re.search(r'output\s+m_axi_rready\s*\n\s*\);', s)
    if not m:
        sys.exit('ERROR: %s: 找不到端口表结尾' % rel)
    ports = '''    output         m_axi_rready  ,

    // ------------------------------------------------------------------
    // A 线：AXI4-Lite 从口 -> PS 的 M_AXI_GP0（视觉结果寄存器 + 帧中断）
    //   时钟域 = UI_CLK（FCLK_CLK0 100 MHz），复位 = rst_n（PS 复位）
    // ------------------------------------------------------------------
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI AWADDR",
       X_INTERFACE_PARAMETER = "XIL_INTERFACENAME S_AXI, PROTOCOL AXI4LITE, DATA_WIDTH 32, ADDR_WIDTH 8, FREQ_HZ 100000000, READ_WRITE_MODE READ_WRITE, HAS_BURST 0, HAS_LOCK 0, HAS_PROT 1, HAS_CACHE 0, HAS_QOS 0, SUPPORTS_NARROW_BURST 0" *)
    input  [7:0]   s_axi_awaddr  ,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI AWPROT" *)
    input  [2:0]   s_axi_awprot  ,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI AWVALID" *)
    input          s_axi_awvalid ,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI AWREADY" *)
    output         s_axi_awready ,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI WDATA" *)
    input  [31:0]  s_axi_wdata   ,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI WSTRB" *)
    input  [3:0]   s_axi_wstrb   ,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI WVALID" *)
    input          s_axi_wvalid  ,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI WREADY" *)
    output         s_axi_wready  ,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI BRESP" *)
    output [1:0]   s_axi_bresp   ,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI BVALID" *)
    output         s_axi_bvalid  ,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI BREADY" *)
    input          s_axi_bready  ,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI ARADDR" *)
    input  [7:0]   s_axi_araddr  ,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI ARPROT" *)
    input  [2:0]   s_axi_arprot  ,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI ARVALID" *)
    input          s_axi_arvalid ,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI ARREADY" *)
    output         s_axi_arready ,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI RDATA" *)
    output [31:0]  s_axi_rdata   ,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI RRESP" *)
    output [1:0]   s_axi_rresp   ,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI RVALID" *)
    output         s_axi_rvalid  ,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI RREADY" *)
    input          s_axi_rready  ,

    // A 线：帧末中断 -> PS 的 IRQ_F2P（经 xlconcat）
    (* X_INTERFACE_INFO = "xilinx.com:signal:interrupt:1.0 irq INTERRUPT",
       X_INTERFACE_PARAMETER = "XIL_INTERFACENAME irq, SENSITIVITY LEVEL_HIGH, PortWidth 1" *)
    output         irq
);'''
    s = s[:m.start()] + ports + s[m.end():]

    # ---- 2. 内部信号
    anchor = "wire         vision_bond_valid;"
    if anchor not in s:
        sys.exit('ERROR: %s: 找不到 vision_bond_valid 声明' % rel)
    s = s.replace(
        anchor,
        anchor + "\nwire  [9:0]  vision_cx, vision_cy, vision_ax, vision_ay;\n"
                 "wire  [143:0] vision_res_extra;\n"
                 "wire         vision_frame_tick;", 1)

    # ---- 3. armor_vision 例化：接出 4 个结果 + 2 个新端口
    inst_re = re.compile(
        r'\.center_x\s*\(\s*\),\s*\n'
        r'\s*\.center_y\s*\(\s*\),\s*\n'
        r'\s*\.aim_x\s*\(\s*\),\s*\n'
        r'\s*\.aim_y\s*\(\s*\)')
    new_inst = ('.center_x   (vision_cx        ),\n'
                '    .center_y   (vision_cy        ),\n'
                '    .aim_x      (vision_ax        ),\n'
                '    .aim_y      (vision_ay        ),\n'
                '    .result_extra (vision_res_extra),\n'
                '    .frame_tick_o (vision_frame_tick)')
    s2, n = inst_re.subn(new_inst, s)
    if n != 1:
        sys.exit('ERROR: %s: armor_vision 例化替换失败 (n=%d)' % (rel, n))
    s = s2

    # ---- 4. vision_regs_axi 例化（放在 endmodule 之前）
    inst = '''
//--------------------------------------------------------------------------
// A 线第一阶段：AXI4-Lite 结果寄存器 + 帧末中断
//   - AXI 侧走 ui_clk（FCLK_CLK0 100 MHz），视觉侧走 lcd_clk（25 MHz）
//   - 每帧把结果快照锁存一次，用 toggle 同步到 AXI 域，PS 读到的是整帧一致的数
//   - irq 是电平：IRQ_STATUS 由 PS 写 1 清零（W1C），与 dart 的驱动约定一致
//--------------------------------------------------------------------------
vision_regs_axi #(
    .SEC_CYCLES (100_000_000)          // 1 s @ FCLK_CLK0 = 100 MHz
) u_vision_regs_axi (
    .s_axi_aclk    (ui_clk                    ),
    .s_axi_aresetn (rst_n                     ),
    .s_axi_awaddr  (s_axi_awaddr              ),
    .s_axi_awprot  (s_axi_awprot              ),
    .s_axi_awvalid (s_axi_awvalid             ),
    .s_axi_awready (s_axi_awready             ),
    .s_axi_wdata   (s_axi_wdata               ),
    .s_axi_wstrb   (s_axi_wstrb               ),
    .s_axi_wvalid  (s_axi_wvalid              ),
    .s_axi_wready  (s_axi_wready              ),
    .s_axi_bresp   (s_axi_bresp               ),
    .s_axi_bvalid  (s_axi_bvalid              ),
    .s_axi_bready  (s_axi_bready              ),
    .s_axi_araddr  (s_axi_araddr              ),
    .s_axi_arprot  (s_axi_arprot              ),
    .s_axi_arvalid (s_axi_arvalid             ),
    .s_axi_arready (s_axi_arready             ),
    .s_axi_rdata   (s_axi_rdata               ),
    .s_axi_rresp   (s_axi_rresp               ),
    .s_axi_rvalid  (s_axi_rvalid              ),
    .s_axi_rready  (s_axi_rready              ),
    .res_clk       (lcd_clk                   ),
    .res_rst_n     (rst_n                     ),
    .frame_tick    (vision_frame_tick         ),
    .valid         (vision_bond_valid         ),
    .cx            (vision_cx                 ),
    .cy            (vision_cy                 ),
    .ax            (vision_ax                 ),
    .ay            (vision_ay                 ),
    .bw            (vision_res_extra[10:0]    ),
    .area          (vision_res_extra[42:11]   ),
    .dist_cm       (vision_res_extra[58:43]   ),
    .drop_px       (vision_res_extra[74:59]   ),
    .vx_q4         (vision_res_extra[90:75]   ),
    .vy_q4         (vision_res_extra[106:91]  ),
    .px            (vision_res_extra[116:107] ),
    .py            (vision_res_extra[126:117] ),
    .fill_q8       (vision_res_extra[134:127] ),
    .blob_cnt      (vision_res_extra[137:135] ),
    .flags         (vision_res_extra[143:138] ),
    .irq           (irq                      )
);
'''
    r = s.rfind('endmodule')
    s = s[:r] + inst + '\n' + s[r:]
    save(rel, p, s)
    print('[ok] %s : +S_AXI/irq ports, +vision_regs_axi instance' % rel)

print('done.')
