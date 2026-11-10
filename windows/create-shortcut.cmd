@echo off
chcp 936 >nul
set "WIN=%~dp0"
echo ============================================
echo   创建桌面快捷方式（带图标）
echo ============================================
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%WIN%make_shortcut.ps1"
echo.
pause
