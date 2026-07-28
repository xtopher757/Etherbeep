@echo off
setlocal
REM EtherBeep: docks in a corner and beeps the moment a port answers 3 pings.

REM Already elevated? Then never prompt. fltmc is a better admin probe than
REM "net session", which also fails when the Server service is stopped and
REM would pop UAC at someone who is already running as admin.
fltmc >nul 2>&1
if %errorlevel%==0 goto run

REM Asked before and got told no? Don't nag on every launch. Admin only buys
REM the 100M pin, so declining is a reasonable standing answer.
set "EBDIR=%LOCALAPPDATA%\EtherBeep"
set "SKIP=%EBDIR%\no-elevate"
if exist "%SKIP%" (
  echo running unelevated - link speed stays on auto
  echo   delete "%SKIP%" to be asked again
  goto run
)

powershell -NoProfile -Command "try { Start-Process -Verb RunAs -FilePath '%~f0' -ErrorAction Stop; exit 0 } catch { exit 1 }"
if %errorlevel%==0 exit /b

REM Here means UAC was declined. Remember it so the next launch goes straight in.
if not exist "%EBDIR%" mkdir "%EBDIR%" >nul 2>&1
break > "%SKIP%"
echo elevation declined - link speed stays on auto
echo   delete "%SKIP%" to be asked again

:run
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0EtherBeep.ps1" %*
