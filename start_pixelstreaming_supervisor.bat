@echo off
setlocal

set "SCRIPT_DIR=%~dp0"
set "PS1=%SCRIPT_DIR%pixelstreaming_supervisor.ps1"

if not exist "%PS1%" (
    echo [ERROR] Missing script: "%PS1%"
    exit /b 1
)

title Pixel Streaming Supervisor
echo Starting Pixel Streaming supervisor...

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%PS1%"

echo.
echo Supervisor exited with code %ERRORLEVEL%.
pause

