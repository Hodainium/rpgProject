@echo off
rem Starts the local backend: docker infra, the game server (:5000) and the verifier worker (:5100). Double-click it.
rem Leave it running while you play; close it with dev_stack_stop.bat. Add --no-worker to skip the verifier.
call "%~dp0dev_stack.bat" start %*
exit /b %ERRORLEVEL%
