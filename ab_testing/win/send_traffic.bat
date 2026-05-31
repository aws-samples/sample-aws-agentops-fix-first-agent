@echo off
REM Send traffic through the AgentCore Gateway for A/B testing.
REM Reads gateway URL from SSM. Uses Python with botocore for SigV4 signing.
REM Usage: send_traffic.bat [prompts_file]

setlocal enabledelayedexpansion

set "SCRIPT_DIR=%~dp0"
set "PROMPTS_FILE=%~1"
if "!PROMPTS_FILE!"=="" set "PROMPTS_FILE=%SCRIPT_DIR%..\prompts.txt"

for /f "tokens=*" %%a in ('aws configure get region 2^>nul') do set "REGION=%%a"
if "!REGION!"=="" set "REGION=us-east-1"
if "!APP_NAME!"=="" set "APP_NAME=fixFirstAgent"

for /f "tokens=*" %%a in ('aws ssm get-parameter --name "/!APP_NAME!/ab-gateway-url" --query Parameter.Value --output text --region !REGION!') do set "GATEWAY_URL=%%a"

echo Gateway URL: !GATEWAY_URL!
python "%SCRIPT_DIR%..\scripts\send_traffic.py" "!GATEWAY_URL!" "!REGION!" "!PROMPTS_FILE!"
echo.
echo Traffic sent at: %date% %time%
echo Evaluation results will be available after: ~20 minutes (session timeout + scoring)
