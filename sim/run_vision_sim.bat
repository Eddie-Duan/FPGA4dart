@echo off
REM ============================================================
REM  armor_vision simulation (xsim, no DDR3 model needed)
REM  Usage: double click, or run in cmd from this folder
REM  If Vivado is not in PATH, edit VIVADO_BIN below.
REM ============================================================
set VIVADO_BIN=D:\Xilinx\Vivado\2020.2\bin
if exist "%VIVADO_BIN%\xvlog.bat" set PATH=%VIVADO_BIN%;%PATH%

cd /d %~dp0

if exist xsim.dir rmdir /s /q xsim.dir
if exist xvlog.log del /q xvlog.log
if exist xelab.log del /q xelab.log

echo ---- compile ----
call xvlog -nolog ^
  ..\rtl\line_buffer.v ^
  ..\rtl\key_debounce.v ^
  ..\rtl\color_seg.v ^
  ..\rtl\morph_nxn.v ^
  ..\rtl\video_delay.v ^
  ..\rtl\proj_bond.v ^
  ..\rtl\overlay_box.v ^
  ..\rtl\seg_display.v ^
  ..\rtl\vision_cfg.v ^
  ..\rtl\median3x3.v ^
  ..\rtl\blob_track.v ^
  ..\rtl\track_ab.v ^
  ..\rtl\aim_predict.v ^
  ..\rtl\ballistic.v ^
  ..\rtl\chroma_hist.v ^
  ..\rtl\vision_stat.v ^
  ..\rtl\uart_tx.v ^
  ..\rtl\uart_rx.v ^
  ..\rtl\result_frame.v ^
  ..\rtl\reg_file.v ^
  ..\rtl\aec_loop.v ^
  ..\rtl\osd_text.v ^
  ..\rtl\armor_vision.v ^
  tb_armor_vision.v
if errorlevel 1 goto err

echo ---- elaborate ----
call xelab -debug typical tb_armor_vision -s tb_vision
if errorlevel 1 goto err

echo ---- simulate ----
call xsim tb_vision -runall
goto end

:err
echo.
echo **** COMPILE / ELABORATE ERROR ****
:end
pause
