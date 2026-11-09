@echo off
rem Runs tools\dev_stack.sh in Git Bash: the whole local backend (docker infra, the game server on :5000, the verifier worker
rem on :5100). Usage: dev_stack.bat <start|stop|restart|status|logs> [options]   (see tools\dev_stack.sh for the options)
rem Double-click dev_stack_start.bat / dev_stack_stop.bat instead. --no-pause: no "press a key" at the end. Set RPG_BASH to
rem a bash.exe to skip the search. Exit code: dev_stack.sh's.
setlocal EnableDelayedExpansion
set "NOPAUSE="
set "ARGS="
for %%A in (%*) do (
	if /I "%%~A"=="--no-pause" (set "NOPAUSE=1") else (set "ARGS=!ARGS! %%~A")
)
set "ROOT=%~dp0.."
for %%R in ("%ROOT%") do set "ROOT=%%~fR"
set "SCRIPT=%ROOT%\tools\dev_stack.sh"
if not exist "%SCRIPT%" (
	echo dev_stack: %SCRIPT% not found
	set "CODE=1"
	goto :done
)
rem Git Bash only: the bash.exe in System32 or WindowsApps is WSL and can't see this project's tools.
set "BASH=%RPG_BASH%"
if not defined BASH if exist "%ProgramFiles%\Git\bin\bash.exe" set "BASH=%ProgramFiles%\Git\bin\bash.exe"
if not defined BASH (
	for /f "delims=" %%G in ('where git 2^>nul') do (
		if not defined BASH if exist "%%~dpG..\bin\bash.exe" set "BASH=%%~dpG..\bin\bash.exe"
		if not defined BASH if exist "%%~dpG..\..\bin\bash.exe" set "BASH=%%~dpG..\..\bin\bash.exe"
	)
)
if not defined BASH (
	echo dev_stack: Git Bash not found. Install Git for Windows or set RPG_BASH to its bin\bash.exe.
	set "CODE=1"
	goto :done
)
pushd "%ROOT%"
set "SH=%SCRIPT:\=/%"
"!BASH!" "!SH!" !ARGS!
set "CODE=!ERRORLEVEL!"
popd
:done
if not defined NOPAUSE pause
exit /b %CODE%
