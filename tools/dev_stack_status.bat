@echo off
rem Shows what is running: server, worker and the docker infra.
call "%~dp0dev_stack.bat" status %*
exit /b %ERRORLEVEL%
