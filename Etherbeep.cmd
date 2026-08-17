@echo off
rem ---------------------------------------------------------------------------
rem  Etherbeep launcher.
rem
rem  Double-click this file to start the monitor window. Keep it in the same
rem  folder as Etherbeep.ps1.
rem
rem  It runs PowerShell with -ExecutionPolicy Bypass for this one process only,
rem  so nothing on the PC has to be reconfigured.
rem ---------------------------------------------------------------------------
setlocal

set "ETHERBEEP=%~dp0Etherbeep.ps1"

if not exist "%ETHERBEEP%" (
    echo.
    echo   Cannot find Etherbeep.ps1 next to this launcher.
    echo   Keep Etherbeep.cmd and Etherbeep.ps1 together in the same folder.
    echo.
    pause
    exit /b 9
)

rem Console mode and -Version print to a console, so run them in this window and
rem hold it open. Everything else is the window, which needs no console at all.
echo %*| findstr /i /c:"-console" /c:"-text" /c:"-version" >nul
if not errorlevel 1 (
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%ETHERBEEP%" -Pause %*
    exit /b %errorlevel%
)

start "" powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "%ETHERBEEP%" %*
exit /b 0
