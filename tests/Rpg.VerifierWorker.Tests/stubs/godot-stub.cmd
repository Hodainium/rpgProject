@echo off
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0godot-stub.ps1" %*
exit /b %errorlevel%
