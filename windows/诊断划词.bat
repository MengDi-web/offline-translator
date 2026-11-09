@echo off
chcp 936 >nul
set "WIN=%~dp0"
echo ============================================
echo   划词助手 诊断模式（错�?会显示在这里�?
echo ============================================
echo.
echo 即将在前台启动划词助手�?��??
echo 如果它�?�常运�?�，窗口会保持打�?（托盘出现图标），按 Ctrl+C �?出�??
echo 如果报错，�?�把红色文字�?图发给开发�?��??
echo.
pause >nul
powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -File "%WIN%xuanci_helper.ps1"
echo.
echo ============================================
echo 划词助手已�??出�??
echo 若上方有错�??信息，�?�截图发送�??
echo 也可以查�? windows\helper.log 的内容�??
echo ============================================
pause
