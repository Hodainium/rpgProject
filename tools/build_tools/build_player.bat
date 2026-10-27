@echo off
rem Builds the player build into build\demo\ (release: the game only, no console, what players get). Double-click it, or run it from a
rem terminal with --no-pause. --check only checks that it can build. See _export.bat.
call "%~dp0_export.bat" player %*
exit /b %ERRORLEVEL%
