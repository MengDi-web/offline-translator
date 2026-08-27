@echo off
chcp 936 >nul
set "ROOT=%~dp0.."
set "WIN=%~dp0"

rem 优先使用「一键部署」装好的便携 Node
if exist "%ROOT%\runtime\node\node.exe" set "PATH=%ROOT%\runtime\node;%PATH%"

echo ============================================
echo   miaomiao翻译器 (Windows 版)
echo ============================================
if not exist "%ROOT%\server.js" (
    echo [错误] 找不到翻译程序 server.js
    echo        你现在是在「压缩包里面」直接双击运行的，这样不行！
    echo        请先退出，右键压缩包选「全部解压」，
    echo        再进入解压出来的文件夹里的 windows 文件夹，运行本脚本。
    pause
    exit /b 1
)

where node >nul 2>&1
if errorlevel 1 (
    echo [错误] 未找到 Node.js，请先双击「一键部署.cmd」完成安装
    pause
    exit /b 1
)

rem 自动启动划词助手（托盘图标，最小化窗口）
start "划词助手" /min powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -File "%WIN%xuanci_helper.ps1"
timeout /t 2 /nobreak >nul
if not exist "%WIN%helper.log" (
    echo [提示] 划词助手似乎未启动成功（没生成 windows\helper.log）
    echo        若划词没反应，请把 windows\helper.log 的内容发给开发者
)

if not exist "%ROOT%\neural\.venv\Scripts\python.exe" (
    echo [提示] 还没运行过「一键部署.cmd」→ 神经翻译不可用，只能查词典
    echo        建议：先关闭本窗口，运行 windows\一键部署.cmd（只需一次），
    echo        装好后再运行本脚本，即可获得完整翻译效果。
    echo.
)
echo 正在启动翻译服务...
echo 启动后请打开浏览器，地址栏输入:  http://127.0.0.1:6688
echo 保持本窗口打开，不要关闭（关闭即停止服务）。
echo 划词翻译：在网页上点一次「开启一键划词」，之后选中文字按 Ctrl+C 即弹窗翻译。
echo.
node "%ROOT%\server.js"

echo.
echo 服务已停止。
pause
