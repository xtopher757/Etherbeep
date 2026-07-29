@echo off
REM EtherBeep: docks in a corner and beeps the moment a port answers 3 pings.
REM Never elevates on its own - a UAC prompt on every double-click was more
REM annoying than the 100M speed win it bought. If you're already in an
REM admin console, EtherBeep pins the test NIC to 100M automatically; if not,
REM it just runs on auto. Right-click this file -> "Run as administrator" if
REM you want 100M without opening an admin console first.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0EtherBeep.ps1" %*
