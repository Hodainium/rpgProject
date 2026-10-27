@echo off
rem Shared by build_player.bat, build_dev.bat and build_full.bat: runs tools\export.sh <level> in Git Bash.
rem   _export.bat <player|dev|full> [--check] [--no-pause]
rem --check: only finds Git Bash and export.sh and exits 0 (the test suite runs this); --no-pause: no "press a key"
rem at the end (scripts, CI). Set RPG_BASH to a bash.exe to skip the search. Exit code: export.sh's (0 = built).
setlocal EnableDelayedExpansion
set "LEVEL=%~1"
set "CHECK="
set "NOPAUSE="
for %%A in (%*) do (
	if /I "%%~A"=="--check" set "CHECK=1"
	if /I "%%~A"=="--no-pause" set "NOPAUSE=1"
)
set "ROOT=%~dp0..\.."
for %%R in ("%ROOT%") do set "ROOT=%%~fR"
set "EXPORT=%ROOT%\tools\export.sh"
if not exist "%EXPORT%" (
	echo build_tools: %EXPORT% not found
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
	echo build_tools: Git Bash not found. Install Git for Windows or set RPG_BASH to its bin\bash.exe.
	set "CODE=1"
	goto :done
)
if defined CHECK (
	echo build_tools: ok, %LEVEL% via "!BASH!" and %EXPORT%
	set "CODE=0"
	goto :done
)
echo Building the %LEVEL% build (about a minute; save all in the Godot editor first)...
pushd "%ROOT%"
set "SCRIPT=%EXPORT:\=/%"
"!BASH!" "!SCRIPT!" %LEVEL%
set "CODE=!ERRORLEVEL!"
popd
if "!CODE!"=="0" (echo Done: see the build folder in %ROOT%\build) else (echo FAILED with exit code !CODE!: see the log in %ROOT%\build)
:done
if not defined NOPAUSE if not defined CHECK pause
exit /b %CODE%
