@echo off
REM Deploy the complete target-based A/B testing infrastructure end-to-end.
REM Usage: deploy_all.bat

setlocal enabledelayedexpansion

set "SCRIPT_DIR=%~dp0"
set "TARGET_DIR=%SCRIPT_DIR%..\target_based_variants"
set "AGENTS_DIR=%TARGET_DIR%\agents"

for /f "tokens=*" %%a in ('aws configure get region 2^>nul') do set "AWS_REGION=%%a"
if "%AWS_REGION%"=="" set "AWS_REGION=us-east-1"
if "%APP_NAME%"=="" set "APP_NAME=fixFirstAgent"

echo === Target-Based A/B Testing Full Deployment ===
echo Region: %AWS_REGION%
echo.

echo === Step 1/3: Packaging agents ===
call "%SCRIPT_DIR%package_agents.bat" "%AGENTS_DIR%"
if errorlevel 1 (echo ERROR: Agent packaging failed & exit /b 1)
echo.

echo === Step 2/3: Deploying runtimes + eval configs ===
call "%SCRIPT_DIR%deploy_agents.bat" "%TARGET_DIR%\cdk_ab_testing"
if errorlevel 1 (echo ERROR: Agent deployment failed & exit /b 1)
echo.

echo === Step 3/3: Deploying gateway + A/B test ===
call "%SCRIPT_DIR%deploy_testing_infra.bat" "%TARGET_DIR%\cdk_ab_gateway"
if errorlevel 1 (echo ERROR: Testing infra deployment failed & exit /b 1)
echo.

echo === Deployment Complete ===
exit /b 0
