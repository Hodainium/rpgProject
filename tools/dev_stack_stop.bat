@echo off
rem Stops the game server, the verifier worker and the docker infra (the data is kept). Double-click it.
rem Add --keep-infra to leave the docker containers running.
call "%~dp0dev_stack.bat" stop %*
exit /b %ERRORLEVEL%
