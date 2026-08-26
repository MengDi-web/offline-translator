@echo off
chcp 936 >nul
cd /d "%~dp0.."

rem 优先使用「一键部署」装好的便携 Node（仅当前会话有效，这里显式加进 PATH）
if exist "runtime\node\node.exe" set "PATH=%CD%\runtime\node;%PATH%"

echo ============================================
echo   miaomiao翻译器 (Windows 版)
echo ============================================

where node >nul 2>&1
if errorlevel 1 (
    echo [错误] 未找到 Node.js，请先双击「一键部署.cmd」完成安装
    pause
    exit /b 1
)

echo [1/2] 检查翻译服务...
curl -s -m 2 http://127.0.0.1:6688/api/stats >nul 2>&1
if errorlevel 1 (
    echo       启动服务...
    start "翻译服务" /min cmd /c "node server.js > server.log 2>&1"
    timeout /t 4 /nobreak >nul
) else (
    echo       服务已在运行
)

echo [2/2] 启动划词助手（右键托盘图标可设置/退出）...
powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -File "windows\xuanci_helper.ps1" 2> "windows\helper_error.log"
if errorlevel 1 (
    echo.
    echo 划词助手启动失败，上方是错误信息（截图发给开发者）
    pause
)
if errorlevel 1 (
    echo.
    echo 划词助手启动失败，上方是错误信息（截图发给开发者）
    pause
)
