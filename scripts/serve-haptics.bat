@echo off
REM ---------------------------------------------------------------
REM One-click file server for the REAPER haptics test bench.
REM
REM Usage (any of):
REM   1. Copy this file into your REAPER export folder, double-click.
REM   2. Drag your export folder onto this file.
REM   3. serve-haptics.bat C:\path\to\export-folder [port]
REM
REM Then on the phone (same Wi-Fi/LAN), REAPER Bench tab, enter the
REM URL printed below and enable Watch.
REM
REM ASCII only: must survive cmd.exe on Chinese-codepage Windows.
REM ---------------------------------------------------------------
setlocal enabledelayedexpansion

set PORT=8765
if not "%~2"=="" set PORT=%~2
if not "%~1"=="" cd /d "%~1"

REM --- locate a python ---
set PY=
where python >nul 2>nul && set PY=python
if "%PY%"=="" if exist "C:\ProgramData\miniconda3\python.exe" set "PY=C:\ProgramData\miniconda3\python.exe"
if "%PY%"=="" if exist "%USERPROFILE%\miniconda3\python.exe" set "PY=%USERPROFILE%\miniconda3\python.exe"
if "%PY%"=="" (
  echo ERROR: python not found. Install python or edit this script.
  pause
  exit /b 1
)

echo.
echo  Serving folder : %CD%
echo  Port           : %PORT%
echo.
echo  Phone URL - pick the address on the same LAN as the phone:
for /f "tokens=2 delims=:" %%a in ('ipconfig ^| findstr /c:"IPv4"') do (
  set "IP=%%a"
  set "IP=!IP: =!"
  echo     http://!IP!:%PORT%/preview.ahap
)
echo.
echo  Convention: export the pattern you are auditioning as
echo  preview.ahap so the phone URL never changes.
echo  Keep this window open. Ctrl+C to stop.
echo.

"%PY%" -m http.server %PORT%
