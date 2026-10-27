@echo off
rem Builds the full build into build\full\ (debug: everything, including the tests). Double-click it, or run it from a
rem terminal with --no-pause. --check only checks that it can build. See _export.bat.
call "%~dp0_export.bat" full %*
exit /b %ERRORLEVEL%
