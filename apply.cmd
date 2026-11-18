@echo off
setlocal
"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -File "%~dp0sogou-adblock.ps1" -Action Apply
set "result=%errorlevel%"
pause
exit /b %result%
