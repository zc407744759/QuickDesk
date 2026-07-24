@echo off
setlocal EnableExtensions EnableDelayedExpansion

if not defined QD_WIN_ALL_ENV_SANITIZED (
    powershell -NoProfile -ExecutionPolicy Bypass -Command "$env:QD_WIN_ALL_ENV_SANITIZED='1'; [Environment]::SetEnvironmentVariable('PATH', $null, 'Process'); $machine=[Environment]::GetEnvironmentVariable('Path','Machine'); $user=[Environment]::GetEnvironmentVariable('Path','User'); $parts=@(); if ($machine) { $parts += $machine }; if ($user) { $parts += $user }; [Environment]::SetEnvironmentVariable('Path', ($parts -join ';'), 'Process'); & $env:ComSpec /d /c '""%~f0"" %*'; exit $LASTEXITCODE"
    exit /B %errorlevel%
)

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

if not defined ENV_QT_PATH (
    if exist "C:\QtPro\6.8.3\msvc2022_64" (
        set "ENV_QT_PATH=C:\QtPro\6.8.3"
    ) else (
        set "ENV_QT_PATH=C:\QtPro\6.8.4"
    )
)

if not defined ENV_VS_INSTALL (
    if exist "C:\BuildTools\VC\Auxiliary\Build\vcvarsall.bat" (
        set "ENV_VS_INSTALL=C:\BuildTools"
    ) else (
        set "ENV_VS_INSTALL=C:\Program Files\Microsoft Visual Studio\2022\Community"
    )
)

if not defined ENV_VCVARSALL (
    set "ENV_VCVARSALL=%ENV_VS_INSTALL%\VC\Auxiliary\Build\vcvarsall.bat"
)

if not defined ENV_VCRUNTIME_VERSION (
    if exist "%ENV_VS_INSTALL%\VC\Redist\MSVC\14.44.35112\x64\Microsoft.VC143.CRT" (
        set "ENV_VCRUNTIME_VERSION=14.44.35112"
    ) else (
        set "ENV_VCRUNTIME_VERSION=14.42.34433"
    )
)

echo [*] ENV_QT_PATH: %ENV_QT_PATH%
echo [*] ENV_VS_INSTALL: %ENV_VS_INSTALL%
echo [*] ENV_VCVARSALL: %ENV_VCVARSALL%
echo [*] ENV_VCRUNTIME_VERSION: %ENV_VCRUNTIME_VERSION%

echo=
echo ---------------------------------------------------------------
echo build
echo ---------------------------------------------------------------
cd /d "%script_path%.."
call "%script_path%build_qd_win.bat" %build_mode% %clean_arg%
if not "%errorlevel%"=="0" (
    echo [!] build failed
    goto return
)

echo=
echo ---------------------------------------------------------------
echo publish
echo ---------------------------------------------------------------
cd /d "%script_path%.."
call "%script_path%publish_qd_win.bat" %build_mode%
if not "%errorlevel%"=="0" (
    echo [!] publish failed
    goto return
)

echo=
echo ---------------------------------------------------------------
echo package
echo ---------------------------------------------------------------
cd /d "%script_path%.."
call "%script_path%package_qd_win.bat" %build_mode%
if not "%errorlevel%"=="0" (
    echo [!] package failed
    goto return
)

echo=
echo ---------------------------------------------------------------
echo [*] full package finished
echo ---------------------------------------------------------------
cd /d "%script_path%.."
echo [*] output: %cd%\publish\QuickDesk-win-x64-setup.exe
set "errno=0"

:return
cd /d "%old_cd%"
exit /B %errno%
