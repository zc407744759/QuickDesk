@echo off
setlocal EnableExtensions EnableDelayedExpansion

set "script_path=%~dp0"
set "old_cd=%cd%"
cd /d "%script_path%.."

set "build_mode=Release"
set "clean_arg="
set "errno=1"

echo=
echo ---------------------------------------------------------------
echo QuickDesk Windows full package
echo ---------------------------------------------------------------

:parse_args
if "%~1"=="" goto args_done
if /i "%~1"=="debug" set "build_mode=Debug"
if /i "%~1"=="release" set "build_mode=Release"
if /i "%~1"=="clean" set "clean_arg=clean"
shift
goto parse_args

:args_done
echo [*] root: %cd%
echo [*] mode: %build_mode%
echo [*] arch: x64
if not "%clean_arg%"=="" echo [*] clean: true

echo=
echo ---------------------------------------------------------------
echo build
echo ---------------------------------------------------------------
call scripts\build_qd_win.bat %build_mode% %clean_arg%
if not "%errorlevel%"=="0" (
    echo [!] build failed
    goto return
)

echo=
echo ---------------------------------------------------------------
echo publish
echo ---------------------------------------------------------------
call scripts\publish_qd_win.bat %build_mode%
if not "%errorlevel%"=="0" (
    echo [!] publish failed
    goto return
)

echo=
echo ---------------------------------------------------------------
echo package
echo ---------------------------------------------------------------
call scripts\package_qd_win.bat %build_mode%
if not "%errorlevel%"=="0" (
    echo [!] package failed
    goto return
)

echo=
echo ---------------------------------------------------------------
echo [*] full package finished
echo ---------------------------------------------------------------
echo [*] output: %cd%\publish\QuickDesk-win-x64-setup.exe
set "errno=0"

:return
cd /d "%old_cd%"
exit /B %errno%
