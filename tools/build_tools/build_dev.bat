@echo off
rem Builds the dev build into build\dev\ (debug: with the backtick console and dev commands). Double-click it, or run it from a
rem terminal with --no-pause. --check only checks that it can build. See _export.bat.
call "%~dp0_export.bat" dev %*
exit /b %ERRORLEVEL%
