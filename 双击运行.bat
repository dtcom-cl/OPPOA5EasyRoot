@echo off
chcp 936 >nul
title OPPO A5 EasyRoot by ycgj
cd /d "%~dp0"

rem ============================================================
rem  Entry point. Chinese messages live in bin\toolkit.ps1.
rem  This file must stay pure ASCII, otherwise cmd shows garbage.
rem ============================================================

if not exist "%~dp0bin\toolkit.ps1" (
  echo.
  echo [ERROR] bin\toolkit.ps1 not found.
  echo         Please keep the whole folder structure intact.
  echo.
  pause
  exit /b 1
)

where powershell >nul 2>nul
if errorlevel 1 (
  echo.
  echo [ERROR] powershell.exe not found. Windows PowerShell is required.
  echo.
  pause
  exit /b 1
)

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0bin\toolkit.ps1" %*

if errorlevel 1 (
  echo.
  echo [ERROR] Toolkit exited with an error. Check the log folder.
)
pause