@echo off
REM Wait for both agent runtimes to become READY.
REM Usage: wait_for_runtimes.bat

setlocal enabledelayedexpansion

for /f "tokens=*" %%a in ('aws configure get region 2^>nul') do set "REGION=%%a"
if "!REGION!"=="" set "REGION=us-east-1"
if "!APP_NAME!"=="" set "APP_NAME=fixFirstAgent"

for /f "tokens=*" %%a in ('aws ssm get-parameter --name "/!APP_NAME!/control-runtime-arn" --query Parameter.Value --output text --region !REGION!') do set "CONTROL_ARN=%%a"
for /f "tokens=*" %%a in ('aws ssm get-parameter --name "/!APP_NAME!/refined-runtime-arn" --query Parameter.Value --output text --region !REGION!') do set "REFINED_ARN=%%a"

REM Extract runtime ID (last segment after /)
for %%a in ("!CONTROL_ARN:/=" "!") do set "CONTROL_ID=%%~a"
for %%a in ("!REFINED_ARN:/=" "!") do set "REFINED_ID=%%~a"

echo Control: !CONTROL_ARN!
echo Treatment: !REFINED_ARN!
echo.

echo Waiting for Control runtime !CONTROL_ID!...
:wait_control
for /f "tokens=*" %%s in ('aws bedrock-agentcore-control get-agent-runtime --agent-runtime-id !CONTROL_ID! --query status --output text --region !REGION! 2^>nul') do set "STATUS=%%s"
if "!STATUS!"=="READY" (
    echo   Control is READY
    goto :done_control
)
echo   !STATUS!
ping -n 21 127.0.0.1 >nul 2>&1
goto wait_control
:done_control

echo Waiting for Treatment runtime !REFINED_ID!...
:wait_treatment
for /f "tokens=*" %%s in ('aws bedrock-agentcore-control get-agent-runtime --agent-runtime-id !REFINED_ID! --query status --output text --region !REGION! 2^>nul') do set "STATUS=%%s"
if "!STATUS!"=="READY" (
    echo   Treatment is READY
    goto :done_treatment
)
echo   !STATUS!
ping -n 21 127.0.0.1 >nul 2>&1
goto wait_treatment
:done_treatment

echo.
echo Both runtimes READY.
exit /b 0
