@echo off
chcp 65001 >nul
cd /d "%~dp0.."

echo ============================================
echo   miaomiao翻译器 (Windows 版)
echo ============================================

where node >nul 2>&1
if errorlevel 1 (
    echo [错误] 未找到 Node.js，请先安装: https://nodejs.org
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
powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -File "windows\xuanci_helper.ps1"
