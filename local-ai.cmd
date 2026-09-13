@echo off
setlocal
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0local-ai-v4.ps1" %*
exit /b %errorlevel%
