@echo off
chcp 936 >nul
set "ROOT=%~dp0.."
set "WIN=%~dp0"

rem 优先使用「一键部署」装好的便携 Node
if exist "%ROOT%\runtime\node\node.exe" set "PATH=%ROOT%\runtime\node;%PATH%"

echo ============================================
echo   miaomiao翻译器 (Windows 版)
echo ============================================

where node >nul 2>&1
if errorlevel 1 (
    echo [错误] 未找到 Node.js，请先双击「一键部署.cmd」完成安装
    pause
    exit /b 1
)

rem 自动启动划词助手（托盘图标，最小化窗口）
start "划词助手" /min powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -File "%WIN%xuanci_helper.ps1"

echo 正在启动翻译服务...
echo 启动后请打开浏览器，地址栏输入:  http://127.0.0.1:6688
echo 保持本窗口打开，不要关闭（关闭即停止服务）。
echo 划词翻译：在网页上点一次「开启一键划词」，之后选中文字按 Ctrl+C 即弹窗翻译。
echo.
node "%ROOT%\server.js"

echo.
echo 服务已停止。
pause
