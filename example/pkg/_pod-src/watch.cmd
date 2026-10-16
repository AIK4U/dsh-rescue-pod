@echo off
rem watch.cmd -- EXAMPLE WATCHDOG launcher (a stand-in).
setlocal
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0watch.ps1" %*
exit /b %ERRORLEVEL%
