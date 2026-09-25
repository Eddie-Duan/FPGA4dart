# =====================================================================================
# timing_peek.tcl -- 直接在已布线的 checkpoint 上问时序，不用重跑实现
#
# 【为什么需要】
#   timing_summary_routed.rpt 里只有「最差的 max_paths 条」，看不到「差一点点」的那些。
#   修完一条路径后如果下一条只是 -0.1ns，就会来回重跑实现（每次十几分钟）。
#   这里一次性把「所有 slack < SLACK_LIMIT 的路径」都列出来，一轮修完。
#
# 【用法】在工程根目录：
#   vivado -mode batch -source tools/timing_peek.tcl -nojournal
# 报告写到 doc/timing_peek.rpt
# =====================================================================================

set script_dir [file dirname [file normalize [info script]]]
set root       [file dirname $script_dir]
set dcp        "$root/prj/ov5640_lcd.runs/impl_1/ov5640_lcd_routed.dcp"
set rpt        "$root/doc/timing_peek.rpt"

set SLACK_LIMIT 1.0     ;# 列出 slack 小于这个值的路径（ns）
set MAX_PATHS   40

if {![file exists $dcp]} {
    error "找不到 $dcp —— 先跑完 implementation"
}

open_checkpoint $dcp

set fh [open $rpt w]
puts $fh "=== 所有 slack < $SLACK_LIMIT ns 的 max-delay 路径（含违例）==="
close $fh

report_timing -delay_type max -sort_by slack -max_paths $MAX_PATHS \
    -slack_lesser_than $SLACK_LIMIT \
    -input_pins -file $rpt -append

#  再按「端点所属模块」做个汇总，一眼看出该改哪个模块
set fh [open $rpt a]
puts $fh "\n\n=== 每个时钟域的 WNS / TNS ==="
close $fh
report_timing_summary -delay_type max -max_paths 1 -file $rpt -append

puts "TIMING_PEEK_DONE -> $rpt"
