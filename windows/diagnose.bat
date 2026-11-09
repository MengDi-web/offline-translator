@echo off
chcp 936 >nul
set "WIN=%~dp0"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%WIN%diagnose.ps1"
pause
