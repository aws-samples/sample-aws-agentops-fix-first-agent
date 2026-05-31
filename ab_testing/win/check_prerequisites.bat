@echo off
REM Check prerequisites for the A/B testing workshop.
REM Exit code: 0 if all prerequisites are met, 1 otherwise.

setlocal enabledelayedexpansion
set "ALL_OK=true"

echo Checking prerequisites...
echo ============================================================

REM Python 3.12+
for /f "tokens=2" %%v in ('python --version 2^>nul') do set "PY_VER=%%v"
if not defined PY_VER (
    echo [FAIL] Python 3.12+: not found
    set "ALL_OK=false"
) else (
    for /f "tokens=1,2 delims=." %%a in ("!PY_VER!") do (
        set "PY_MAJOR=%%a"
        set "PY_MINOR=%%b"
    )
    if !PY_MAJOR! GEQ 3 if !PY_MINOR! GEQ 12 (
        echo [OK] Python 3.12+: !PY_VER!
    ) else (
        echo [FAIL] Python 3.12+: !PY_VER! - need 3.12+
        set "ALL_OK=false"
    )
)

REM uv
uv --version >nul 2>&1
if %errorlevel% equ 0 (
    for /f "tokens=*" %%v in ('uv --version 2^>nul') do echo [OK] uv: %%v
) else (
    echo [FIXING] uv not found, installing...
    pip install uv >nul 2>&1
    uv --version >nul 2>&1
    if !errorlevel! equ 0 (echo [OK] uv installed) else (echo [FAIL] uv installation failed & set "ALL_OK=false")
)

REM Node.js
node --version >nul 2>&1
if %errorlevel% equ 0 (
    for /f "tokens=*" %%v in ('node --version 2^>nul') do echo [OK] Node.js: %%v
) else (
    echo [FAIL] Node.js not found
    set "ALL_OK=false"
)

REM AWS CLI >= 2.34
aws --version >nul 2>&1
if %errorlevel% equ 0 (
    for /f "tokens=2 delims=/" %%v in ('aws --version 2^>nul') do set "CLI_VER=%%v"
    for /f "tokens=1,2 delims=." %%a in ("!CLI_VER!") do (
        set "CLI_MAJOR=%%a"
        set "CLI_MINOR=%%b"
    )
    if !CLI_MAJOR! GEQ 2 if !CLI_MINOR! GEQ 34 (
        echo [OK] AWS CLI: !CLI_VER!
    ) else (
        echo [FAIL] AWS CLI !CLI_VER! is too old. Need ^>= 2.34.
        set "ALL_OK=false"
    )
) else (
    echo [FAIL] AWS CLI not found
    set "ALL_OK=false"
)

REM AWS credentials
aws sts get-caller-identity >nul 2>&1
if %errorlevel% equ 0 (
    for /f "tokens=*" %%a in ('aws sts get-caller-identity --query Arn --output text 2^>nul') do echo [OK] AWS credentials: %%a
) else (
    echo [FAIL] AWS credentials not configured or expired
    set "ALL_OK=false"
)

REM CDK bootstrapped
for /f "tokens=*" %%s in ('aws cloudformation describe-stacks --stack-name CDKToolkit --query Stacks[0].StackStatus --output text 2^>nul') do set "CDK_STATUS=%%s"
echo !CDK_STATUS! | findstr /i "COMPLETE" >nul 2>&1
if %errorlevel% equ 0 (
    echo [OK] CDK bootstrapped
) else (
    echo [FIXING] CDK not bootstrapped, running cdk bootstrap...
    npx cdk bootstrap >nul 2>&1
    if !errorlevel! equ 0 (echo [OK] CDK bootstrapped) else (echo [FAIL] CDK bootstrap failed & set "ALL_OK=false")
)

REM pip packages
for %%p in (requests botocore) do (
    python -c "import %%p" >nul 2>&1
    if !errorlevel! equ 0 (
        echo [OK] %%p package
    ) else (
        echo [FIXING] %%p not found, installing...
        python -m pip install %%p >nul 2>&1
        python -c "import %%p" >nul 2>&1
        if !errorlevel! equ 0 (echo [OK] %%p installed) else (echo [FAIL] %%p installation failed & set "ALL_OK=false")
    )
)

echo ============================================================
if "!ALL_OK!"=="true" (
    echo All prerequisites satisfied!
    exit /b 0
) else (
    echo Some prerequisites need manual action.
    exit /b 1
)
