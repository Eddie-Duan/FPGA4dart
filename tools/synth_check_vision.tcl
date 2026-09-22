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
#
#  Reports: doc/synth_utilization_vision.rpt
#           doc/synth_utilization_hier.rpt
#  What to look at:
#      "LUT as Memory"  -> must be ~2000 (line buffers inferred as LUTRAM)
#      "Slice Registers"-> must be small (~800), not tens of thousands
# ===========================================================

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
    $rtl/vision_cfg.v \
    $rtl/armor_vision.v ]

synth_design -top armor_vision -part xc7a35tfgg484-2 -mode out_of_context

report_utilization -file "$doc/synth_utilization_vision.rpt"
report_utilization -hierarchical -file "$doc/synth_utilization_hier.rpt"
report_utilization
puts "SYNTH_CHECK_DONE"
