@echo off
REM Deploy the A/B testing gateway infrastructure: gateway + targets + A/B test.
REM Usage: deploy_testing_infra.bat [cdk_dir]

setlocal enabledelayedexpansion

set "CDK_DIR=%~1"
if "%CDK_DIR%"=="" set "CDK_DIR=%~dp0..\target_based_variants\cdk_ab_gateway"

for /f "tokens=*" %%a in ('aws configure get region 2^>nul') do set "REGION=%%a"
if "%REGION%"=="" set "REGION=us-east-1"
if "%APP_NAME%"=="" set "APP_NAME=fixFirstAgent"

echo Deploying A/B testing gateway infrastructure...
cd /d "%CDK_DIR%"

if not exist "node_modules" (
    echo Installing CDK dependencies...
    npm install
)

REM Read ARNs from SSM
for /f "tokens=*" %%a in ('aws ssm get-parameter --name "/%APP_NAME%/control-runtime-arn" --query Parameter.Value --output text --region %REGION%') do set "CONTROL_RUNTIME_ARN=%%a"
for /f "tokens=*" %%a in ('aws ssm get-parameter --name "/%APP_NAME%/refined-runtime-arn" --query Parameter.Value --output text --region %REGION%') do set "REFINED_RUNTIME_ARN=%%a"
for /f "tokens=*" %%a in ('aws ssm get-parameter --name "/%APP_NAME%/control-eval-arn" --query Parameter.Value --output text --region %REGION%') do set "CONTROL_EVAL_ARN=%%a"
for /f "tokens=*" %%a in ('aws ssm get-parameter --name "/%APP_NAME%/treatment-eval-arn" --query Parameter.Value --output text --region %REGION%') do set "TREATMENT_EVAL_ARN=%%a"

echo Control Runtime: %CONTROL_RUNTIME_ARN%
echo Refined Runtime: %REFINED_RUNTIME_ARN%

npx cdk deploy fixFirstAgent-ABGatewayStack --require-approval never -c "controlRuntimeArn=%CONTROL_RUNTIME_ARN%" -c "refinedRuntimeArn=%REFINED_RUNTIME_ARN%" -c "controlEvalArn=%CONTROL_EVAL_ARN%" -c "treatmentEvalArn=%TREATMENT_EVAL_ARN%"
if errorlevel 1 (
    echo ERROR: Gateway stack deployment failed
    exit /b 1
)

for /f "tokens=*" %%a in ('aws ssm get-parameter --name "/%APP_NAME%/ab-gateway-url" --query Parameter.Value --output text --region %REGION%') do set "GATEWAY_URL=%%a"
for /f "tokens=*" %%a in ('aws ssm get-parameter --name "/%APP_NAME%/ab-test-id" --query Parameter.Value --output text --region %REGION%') do set "AB_TEST_ID=%%a"

echo.
echo === A/B Testing Infrastructure Ready ===
echo Gateway URL: %GATEWAY_URL%
echo A/B Test ID: %AB_TEST_ID%
exit /b 0
