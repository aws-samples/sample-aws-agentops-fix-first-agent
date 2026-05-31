@echo off
REM Run the complete target-based A/B testing workflow end-to-end.
REM Usage: run_target_ab_testing.bat

setlocal enabledelayedexpansion

set "SCRIPT_DIR=%~dp0"
set "AB_DIR=%SCRIPT_DIR%.."
set "TARGET_DIR=%AB_DIR%\target_based_variants"

for /f "tokens=*" %%a in ('aws configure get region 2^>nul') do set "AWS_REGION=%%a"
if "!AWS_REGION!"=="" set "AWS_REGION=us-east-1"
if "!APP_NAME!"=="" set "APP_NAME=fixFirstAgent"

echo ============================================================
echo   Target-Based A/B Testing - End-to-End
echo ============================================================
echo Region: !AWS_REGION!
echo.

echo === Step 1/7: Checking prerequisites ===
call "%SCRIPT_DIR%check_prerequisites.bat"
if errorlevel 1 (echo ERROR: Prerequisites not met. & exit /b 1)
echo.

echo === Step 2/7: Packaging agents ===
call "%SCRIPT_DIR%package_agents.bat" "%TARGET_DIR%\agents"
if errorlevel 1 (echo ERROR: Agent packaging failed & exit /b 1)
echo.

echo === Step 3/7: Deploying runtimes + eval configs ===
call "%SCRIPT_DIR%deploy_agents.bat" "%TARGET_DIR%\cdk_ab_testing"
if errorlevel 1 (echo ERROR: Agent deployment failed & exit /b 1)
echo.

echo === Step 4/7: Deploying gateway + A/B test ===
call "%SCRIPT_DIR%deploy_testing_infra.bat" "%TARGET_DIR%\cdk_ab_gateway"
if errorlevel 1 (echo ERROR: Gateway deployment failed & exit /b 1)
echo.

echo === Step 5/7: Waiting for runtimes to become READY ===
for /f "tokens=*" %%a in ('aws ssm get-parameter --name "/!APP_NAME!/control-runtime-arn" --query Parameter.Value --output text --region !AWS_REGION!') do set "CONTROL_ARN=%%a"
for /f "tokens=*" %%a in ('aws ssm get-parameter --name "/!APP_NAME!/refined-runtime-arn" --query Parameter.Value --output text --region !AWS_REGION!') do set "REFINED_ARN=%%a"

for %%n in ("Control:!CONTROL_ARN!" "Treatment:!REFINED_ARN!") do (
    for /f "tokens=1,2 delims=:" %%a in (%%n) do (
        set "VNAME=%%a"
        for /f "tokens=4 delims=/" %%i in ("%%b") do set "RID=%%i"
    )
    echo Waiting for !VNAME! runtime !RID!...
    for /l %%i in (1,1,30) do (
        for /f "tokens=*" %%s in ('aws bedrock-agentcore-control get-agent-runtime --agent-runtime-id !RID! --region !AWS_REGION! --query status --output text 2^>nul') do set "STATUS=%%s"
        if "!STATUS!"=="READY" (
            echo   !VNAME! is READY
            goto :next_!VNAME!
        )
        echo   [%%i/30] !STATUS!
        timeout /t 20 /nobreak >nul
    )
    echo ERROR: !VNAME! runtime not READY after 10 minutes
    exit /b 1
    :next_!VNAME!
)
echo.

echo === Step 6/7: Sending traffic through gateway ===
for /f "tokens=*" %%a in ('aws ssm get-parameter --name "/!APP_NAME!/ab-gateway-url" --query Parameter.Value --output text --region !AWS_REGION!') do set "GATEWAY_URL=%%a"
call "%SCRIPT_DIR%send_traffic.bat" "!GATEWAY_URL!" "!AWS_REGION!" "%AB_DIR%\prompts.txt"
if errorlevel 1 (echo ERROR: Send traffic failed & exit /b 1)
echo.

echo === Step 7/7: Checking A/B test results ===
for /f "tokens=*" %%a in ('aws ssm get-parameter --name "/!APP_NAME!/ab-test-id" --query Parameter.Value --output text --region !AWS_REGION!') do set "AB_TEST_ID=%%a"
echo A/B Test ID: !AB_TEST_ID!
echo Waiting for results (polling every 60s, up to 20 min)...

for /l %%i in (1,1,20) do (
    for /f "tokens=*" %%s in ('aws bedrock-agentcore get-ab-test --ab-test-id !AB_TEST_ID! --region !AWS_REGION! --query "results.evaluatorMetrics[0].controlStats.sampleSize" --output text 2^>nul') do set "SAMPLES=%%s"
    if defined SAMPLES if not "!SAMPLES!"=="None" if not "!SAMPLES!"=="" (
        echo Results available!
        echo.
        echo ============================================================
        echo   A/B TEST RESULTS
        echo ============================================================
        aws bedrock-agentcore get-ab-test --ab-test-id !AB_TEST_ID! --region !AWS_REGION! --query "{Status:status,Execution:executionStatus,Control:{Mean:results.evaluatorMetrics[0].controlStats.mean,Samples:results.evaluatorMetrics[0].controlStats.sampleSize},Treatment:{Mean:results.evaluatorMetrics[0].variantResults[0].mean,Samples:results.evaluatorMetrics[0].variantResults[0].sampleSize,PercentChange:results.evaluatorMetrics[0].variantResults[0].percentChange,PValue:results.evaluatorMetrics[0].variantResults[0].pValue,Significant:results.evaluatorMetrics[0].variantResults[0].isSignificant}}" --output table
        echo ============================================================
        exit /b 0
    )
    echo   [%%i/20] No results yet, waiting 60s...
    timeout /t 60 /nobreak >nul
)

echo WARNING: Results not available after 20 minutes.
echo   aws bedrock-agentcore get-ab-test --ab-test-id !AB_TEST_ID! --region !AWS_REGION!
exit /b 0
