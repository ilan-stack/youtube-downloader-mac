@echo off
REM Build YouTubeDownloader.exe via PyInstaller, plus an Inno Setup installer if available.
REM Prerequisites: Python 3.11+ on PATH. Optional: Inno Setup for the installer step.
setlocal

cd /d "%~dp0"

if not exist .venv (
    echo Creating virtualenv ...
    python -m venv .venv || goto :err
)

call .venv\Scripts\activate.bat
python -m pip install --upgrade pip
python -m pip install -r requirements.txt || goto :err

REM Fetch any missing binaries — checks deno.exe too since it was added later.
if not exist bin\yt-dlp.exe goto :fetch
if not exist bin\ffmpeg.exe goto :fetch
if not exist bin\ffprobe.exe goto :fetch
if not exist bin\deno.exe goto :fetch
goto :fetch_done
:fetch
echo Fetching bundled binaries ...
powershell -ExecutionPolicy Bypass -File fetch-binaries.ps1 || goto :err
:fetch_done

rmdir /s /q build 2>nul
rmdir /s /q dist 2>nul

pyinstaller --clean youtube-downloader.spec || goto :err

echo.
echo ===========================================
echo Built: dist\YouTubeDownloader.exe
echo Size:
dir dist\YouTubeDownloader.exe | findstr "YouTubeDownloader"
echo ===========================================

REM Build installer if Inno Setup is installed
set "ISCC="
for %%P in (
    "%ProgramFiles(x86)%\Inno Setup 6\ISCC.exe"
    "%ProgramFiles%\Inno Setup 6\ISCC.exe"
    "%ProgramFiles(x86)%\Inno Setup 5\ISCC.exe"
) do (
    if exist %%P set "ISCC=%%~P"
)

if defined ISCC (
    echo.
    echo Inno Setup found — compiling installer ...
    "%ISCC%" installer.iss || goto :err
    echo.
    echo ===========================================
    echo Built installer: Output\YouTubeDownloader-Setup.exe
    dir Output\YouTubeDownloader-Setup.exe | findstr "Setup"
    echo ===========================================
) else (
    echo.
    echo NOTE: Inno Setup not installed — skipping installer step.
    echo Install with:   winget install JRSoftware.InnoSetup
    echo Then re-run:    build.bat
)

goto :eof

:err
echo.
echo Build failed.
exit /b 1
