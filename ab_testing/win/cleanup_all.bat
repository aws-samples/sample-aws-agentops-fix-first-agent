@echo off
REM Tear down ALL target-based A/B testing infrastructure.
REM Usage: cleanup_all.bat

setlocal enabledelayedexpansion

set "SCRIPT_DIR=%~dp0"
set "TARGET_DIR=%SCRIPT_DIR%..\target_based_variants"

for /f "tokens=*" %%a in ('aws configure get region 2^>nul') do set "AWS_REGION=%%a"
if "%AWS_REGION%"=="" set "AWS_REGION=us-east-1"
if "%APP_NAME%"=="" set "APP_NAME=fixFirstAgent"

echo === Target-Based A/B Testing Full Cleanup ===
echo Region: %AWS_REGION%
echo.

echo === Step 1/2: Cleaning up gateway infrastructure ===
python "%TARGET_DIR%\scripts\cleanup_ab_test.py"
echo.

echo === Step 2/2: Destroying CDK stacks ===

echo Destroying fixFirstAgent-ABGatewayStack...
cd /d "%TARGET_DIR%\cdk_ab_gateway"
npx cdk destroy fixFirstAgent-ABGatewayStack --force 2>nul
if errorlevel 1 echo   (stack may not exist, continuing)

echo Destroying fixFirstAgent-ABTestingStack...
cd /d "%TARGET_DIR%\cdk_ab_testing"
npx cdk destroy fixFirstAgent-ABTestingStack --force 2>nul
if errorlevel 1 echo   (stack may not exist, continuing)

echo.
echo === Cleanup Complete ===
exit /b 0
