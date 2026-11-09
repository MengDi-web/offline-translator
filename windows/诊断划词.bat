@echo off
chcp 936 >nul
set "WIN=%~dp0"
echo ============================================
echo   划词助手 诊断模式（错误会显示在这里）
echo ============================================
echo.
echo 即将在前台启动划词助手……
echo 如果它正常运行，窗口会保持打开（托盘出现图标），按 Ctrl+C 退出。
echo 如果报错，请把红色文字截图发给开发者。
echo.
pause >nul
powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -File "%WIN%xuanci_helper.ps1"
echo.
echo ============================================
echo 划词助手已退出。
echo 若上方有错误信息，请截图发送。
echo 也可以查看 windows\helper.log 的内容。
echo ============================================
pause
