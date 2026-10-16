@echo off
rem rescue.cmd -- EXAMPLE ENTRY (a stand-in).
rem
rem ASCII-only on purpose, and it never writes a path literal: %~dp0 is expanded by
rem cmd.exe at run time. A .cmd whose BODY contains a non-ASCII path is decoded with
rem the console code page, and the command silently does nothing.
setlocal
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0rescue.ps1" %*
exit /b %ERRORLEVEL%
