@echo off
REM Check A/B test results with formatted output.
REM Usage: check_ab_results.bat

set "SCRIPT_DIR=%~dp0"
python "%SCRIPT_DIR%..\scripts\check_ab_results.py"
