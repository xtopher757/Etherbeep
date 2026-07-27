@echo off
REM EtherBeep: docks in a corner and beeps the moment a port answers 3 pings.
REM Try to elevate first - admin is what lets EtherBeep pin the test NIC to
REM 100M full-duplex, which cuts ~1-2s of gigabit autonegotiation off every
REM cable move. Declining the UAC prompt is fine: it just runs unelevated and
REM leaves the adapter on auto.
net session >nul 2>&1
if %errorlevel%==0 goto run
powershell -NoProfile -Command "Start-Process -Verb RunAs -FilePath '%~f0'" >nul 2>&1 && exit /b
:run
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0EtherBeep.ps1" %*
