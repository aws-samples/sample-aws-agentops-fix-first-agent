@echo off
REM Deploy both agent runtimes and evaluation configs to AgentCore via CDK.
REM Usage: deploy_agents.bat [cdk_dir]

setlocal
set "CDK_DIR=%~1"
if "%CDK_DIR%"=="" set "CDK_DIR=%~dp0..\target_based_variants\cdk_ab_testing"

echo Deploying agent runtimes and evaluation configs...
cd /d "%CDK_DIR%"

if not exist "node_modules" (
    echo Installing CDK dependencies...
    npm install
)

npx cdk deploy fixFirstAgent-ABTestingStack --require-approval never
if errorlevel 1 (
    echo ERROR: Agent runtime deployment failed
    exit /b 1
)

echo Agent runtimes and evaluation configs deployed.
exit /b 0
