# =====================================================================================
# add_sources_vivado.tcl -- 把 rtl/ 下的 Verilog 源文件注册进当前工程
#
# 【为什么必须用这个脚本，而不能改 .xpr】
#   .xpr 不是「配置文件」，它是 Vivado 的内部数据库。只要工程在 Vivado 里打开着，
#   任何一次保存都会用**内存里的**文件列表覆盖磁盘上的 .xpr。
#   实测：外部注册的 11 个新模块被反复抹掉，综合报
#       [Synth 8-439] module 'uart_rx' not found
#   所以「往工程里加文件」这件事必须让 Vivado 自己来做。
#
# 【用法】Vivado 菜单 Window -> Tcl Console，粘贴下面这一行回车：
#       source {C:/Users/DUANboyang/Desktop/FPGA4dart/tools/add_sources_vivado.tcl}
#   脚本会自己从路径推出工程根目录、没开工程就自己打开，不需要先 cd。
#   跑完再 Run Synthesis。可重复执行（已在工程里的会自动跳过）。
# =====================================================================================

# ---- 0) 定位工程根目录：用脚本自身路径，比 pwd 可靠 ----
set script_dir [file dirname [file normalize [info script]]]
set root       [file dirname $script_dir]
set rtl        [file join $root rtl]
set xpr        [file join $root prj ov5640_lcd.xpr]

puts "== 工程根目录 : $root"
puts "== 源文件目录 : $rtl"

if {![file isdirectory $rtl]} {
    error "找不到 $rtl —— 请确认工程目录结构没变（应有 rtl/ prj/ sim/ 三个子目录）"
}

# ---- 1) 没开工程就自己打开 ----
set cur ""
catch {set cur [current_project -quiet]}
if {$cur eq ""} {
    if {![file exists $xpr]} { error "找不到工程文件：$xpr" }
    open_project $xpr
    puts "== 已打开工程：$xpr"
} else {
    puts "== 当前已打开工程：$cur"
}

# ---- 2) 补齐 rtl/ 下所有 .v 到 sources_1 ----
set files [lsort [glob -nocomplain [file join $rtl *.v]]]
if {[llength $files] == 0} { error "$rtl 下没有 .v 文件" }

set added 0
set had   0
foreach f $files {
    if {[llength [get_files -quiet $f]] > 0} {
        incr had
    } else {
        add_files -fileset sources_1 -norecurse $f
        incr added
        puts "  + [file tail $f]"
    }
}
puts "== 新增 $added 个，本来就在 $had 个"

# ---- 3) 顶层模块 ----
set top_now [get_property top [get_filesets sources_1]]
if {$top_now ne "ov5640_lcd"} {
    set_property top ov5640_lcd [get_filesets sources_1]
    puts "== 顶层模块：$top_now -> ov5640_lcd"
} else {
    puts "== 顶层模块：ov5640_lcd（正确）"
}

# ---- 4) 重建编译顺序（关键：不重建的话新文件可能不参与综合）----
update_compile_order -fileset sources_1

# ---- 5) 汇总，并逐一确认 11 个新模块都在 ----
set want {vision_stat.v blob_track.v track_ab.v chroma_hist.v median3x3.v \
          uart_tx.v uart_rx.v result_frame.v reg_file.v aec_loop.v osd_text.v}
set lack {}
foreach w $want {
    if {[llength [get_files -quiet [file join $rtl $w]]] == 0} { lappend lack $w }
}

set n [llength [get_files -of_objects [get_filesets sources_1]]]
puts "== sources_1 现在共 $n 个文件"
if {[llength $lack] == 0} {
    puts "== 11 个新模块全部就位，可以 Run Synthesis 了。"
} else {
    puts "!! 仍然缺少：$lack"
}
