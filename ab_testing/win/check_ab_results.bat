@echo off
REM Check target-based A/B test results with pretty-printed output.
REM Usage: check_ab_results.bat

set "SCRIPT_DIR=%~dp0"
python "%SCRIPT_DIR%..\scripts\check_ab_results.py" ab-test-id
