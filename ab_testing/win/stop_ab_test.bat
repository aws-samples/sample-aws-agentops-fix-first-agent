@echo off
REM Stop the A/B test.
REM Usage: stop_ab_test.bat

setlocal enabledelayedexpansion

for /f "tokens=*" %%a in ('aws configure get region 2^>nul') do set "REGION=%%a"
if "!REGION!"=="" set "REGION=us-east-1"
if "!APP_NAME!"=="" set "APP_NAME=fixFirstAgent"

for /f "tokens=*" %%a in ('aws ssm get-parameter --name "/!APP_NAME!/ab-test-id" --query Parameter.Value --output text --region !REGION!') do set "AB_TEST_ID=%%a"
aws bedrock-agentcore update-ab-test --ab-test-id !AB_TEST_ID! --execution-status STOPPED --region !REGION!
echo A/B test !AB_TEST_ID! stopped.
exit /b 0
