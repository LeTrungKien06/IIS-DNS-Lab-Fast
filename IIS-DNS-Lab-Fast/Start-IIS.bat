@echo off
setlocal
cd /d "%~dp0"

net session >nul 2>&1
if %errorlevel% neq 0 (
    powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
    exit /b
)

if not exist "%~dp0lab-config.json" (
    echo.
    echo First run: configure this computer's IIS IP and DNS Server IP.
    powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0Setup-Server.ps1"
    if errorlevel 1 (
        pause
        exit /b 1
    )
)

if not exist "%~dp0dns-credential.xml" (
    echo.
    echo DNS credentials have not been saved yet.
    echo Run Save-DNSCredential.ps1 after the DNS Server is ready.
    pause
    exit /b 1
)

powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0Fast-Portal.ps1"
