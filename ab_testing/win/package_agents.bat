@echo off
REM Package both agent variants for AgentCore Runtime (aarch64 Linux).
REM Usage: package_agents.bat <agents_dir>

setlocal enabledelayedexpansion

set "AGENTS_DIR=%~1"
if "%AGENTS_DIR%"=="" set "AGENTS_DIR=."

call :package_agent "%AGENTS_DIR%\control"
if errorlevel 1 exit /b 1

call :package_agent "%AGENTS_DIR%\treatment"
if errorlevel 1 exit /b 1

echo Both agents packaged successfully.
exit /b 0

:package_agent
set "AGENT_DIR=%~1"
set "BUILD_DIR=%AGENT_DIR%\build"

echo Packaging %AGENT_DIR%...

REM Clean and create build directory
if exist "%BUILD_DIR%" rmdir /s /q "%BUILD_DIR%"
mkdir "%BUILD_DIR%"

REM Install dependencies for aarch64 linux
uv pip install --python-platform aarch64-manylinux2014 --python-version 3.12 --target "%BUILD_DIR%" -r "%AGENT_DIR%\requirements.txt"
if errorlevel 1 (
    echo ERROR: Failed to install dependencies for %AGENT_DIR%
    exit /b 1
)

REM Copy agent source code
xcopy /s /e /y /q "%AGENT_DIR%\src\*" "%BUILD_DIR%\" >nul

REM Explicitly copy opentelemetry-instrument (xcopy may skip extensionless files)
copy /y "%AGENT_DIR%\src\bin\opentelemetry-instrument" "%BUILD_DIR%\bin\opentelemetry-instrument" >nul 2>&1

REM Remove Windows .exe wrappers from bin/
if exist "%BUILD_DIR%\bin\*.exe" del /q "%BUILD_DIR%\bin\*.exe"

echo Done: %BUILD_DIR%
exit /b 0
