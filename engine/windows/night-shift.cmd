@echo off
rem night-shift on Windows: hands the call to the engine in WSL2 (see night-shift-wsl.ps1).
setlocal
set "NS_TOOL=night-shift"
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0night-shift-wsl.ps1" %*
exit /b %ERRORLEVEL%
