@echo off
REM ============================================================
REM  vision_regs_axi simulation (xsim, no DDR3 / IP needed)
REM  Usage: double click, or run in cmd from this folder
REM ============================================================
set VIVADO_BIN=D:\Xilinx\Vivado\2020.2\bin
if exist "%VIVADO_BIN%\xvlog.bat" set PATH=%VIVADO_BIN%;%PATH%

cd /d %~dp0

if exist xsim.dir rmdir /s /q xsim.dir
if exist xvlog.log del /q xvlog.log
if exist xelab.log del /q xelab.log

echo ---- compile ----
call xvlog -nolog ..\rtl\vision_regs_axi.v tb_vision_regs_axi.v
if errorlevel 1 goto err

echo ---- elaborate ----
call xelab -debug typical tb_vision_regs_axi -s tb_regs
if errorlevel 1 goto err

echo ---- simulate ----
call xsim tb_regs -runall
goto end

:err
echo.
echo **** COMPILE / ELABORATE ERROR ****
:end
pause
