# ===========================================================
#  synth_check_vision.tcl
#  Out-of-context synthesis of the armor_vision pipeline.
#
#  Why: a plain RTL simulation can pass while Vivado still fails to
#  infer LUTRAM (or uses far too many LUTs). This script checks the
#  real synthesized resource usage without needing the DDR3 /
#  clk_wiz IPs, so it runs in a couple of minutes.
#
#  Usage (from anywhere):
#      vivado -mode batch -source tools/synth_check_vision.tcl
#      vivado -mode batch -source tools/synth_check_vision.tcl -tclargs -timing   # 多跑一次时序预检
#
#  Reports: doc/synth_utilization_vision.rpt
#           doc/synth_utilization_hier.rpt
#           doc/synth_timing_precheck.rpt        （只在 -timing 时生成）
#  What to look at:
#      "LUT as Memory"  -> must be ~2000 (line buffers inferred as LUTRAM)
#      "Slice Registers"-> must be small (~800), not tens of thousands
#      PRECHECK_WNS     -> 必须 > 0（-timing 时才有）
# ===========================================================

#  -timing：给 OOC 综合加一个 20ns 时钟（= clk_out2 的 50MHz）并报告 slack。
#  为什么值得：本次 review 踩过一次「OOC 综合 0 error/0 warning，但 implementation
#  报 WNS -5.242ns」—— 因为 OOC 根本不带时序约束。这个预检几十秒就能抓出
#  「组合链长到 25ns」这类粗错，不用等十几分钟的实现。
#  注意：OOC 没有布线信息，这里的 slack 只是逻辑级数估算，**不能代替 implementation**。
set do_timing [expr {[lsearch -exact $argv "-timing"] >= 0}]

# project root = one level above this script (tools/..)
set root [file dirname [file dirname [file normalize [info script]]]]
set rtl  "$root/rtl"
set doc  "$root/doc"

read_verilog [list \
    $rtl/line_buffer.v \
    $rtl/key_debounce.v \
    $rtl/color_seg.v \
    $rtl/morph_nxn.v \
    $rtl/video_delay.v \
    $rtl/proj_bond.v \
    $rtl/overlay_box.v \
    $rtl/seg_display.v \
    $rtl/vision_cfg.v \
    $rtl/median3x3.v \
    $rtl/blob_track.v \
    $rtl/track_ab.v \
    $rtl/aim_predict.v \
    $rtl/ballistic.v \
    $rtl/temporal_acc.v \
    $rtl/chroma_hist.v \
    $rtl/vision_stat.v \
    $rtl/uart_tx.v \
    $rtl/uart_rx.v \
    $rtl/result_frame.v \
    $rtl/reg_file.v \
    $rtl/aec_loop.v \
    $rtl/osd_text.v \
    $rtl/armor_vision.v ]

synth_design -top armor_vision -part xc7a35tfgg484-2 -mode out_of_context

report_utilization -file "$doc/synth_utilization_vision.rpt"
report_utilization -hierarchical -file "$doc/synth_utilization_hier.rpt"
report_utilization

if {$do_timing} {
    puts "\n==== 时序预检（OOC 估算，仅供参考）===="
    create_clock -period 20.000 -name ooc_clk [get_ports clk]
    report_timing_summary -delay_type max -max_paths 5 \
        -file "$doc/synth_timing_precheck.rpt"
    set wns [get_property SLACK [get_timing_paths -delay_type max -max_paths 1]]
    if {$wns < 0} {
        puts "PRECHECK_WNS = $wns ns   <<<< 负值：组合链太长，先修再加实现"
    } else {
        puts "PRECHECK_WNS = $wns ns   （OOC 估算，正式结论看 implementation）"
    }
}
puts "SYNTH_CHECK_DONE"
