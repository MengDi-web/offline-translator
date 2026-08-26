@echo off
chcp 936 >nul
set "WIN=%~dp0"
set "PS1=%WIN%xuanci_helper.ps1"
if not exist "%PS1%" set "PS1=%WIN%..\windows\xuanci_helper.ps1"
if not exist "%PS1%" (
    echo [错误] 找不到 xuanci_helper.ps1
    echo        排错.cmd 所在文件夹: %WIN%
    echo        该文件夹里的文件:
    dir /b "%WIN%"
    echo.
    echo        请把 排错.cmd 和 xuanci_helper.ps1 放在同一个文件夹里再运行。
    echo        （正常解压后它们都在 windows 文件夹里，不要单独把排错.cmd 拷走）
    pause
    exit /b 1
)
echo 使用脚本: %PS1%
echo.
echo ============================================
echo   miaomiao翻译器 · 划词助手排错工具
echo   作用: 启动助手并把任何错误写入
echo         helper_error.txt
echo ============================================
echo.
echo 如果下面出现错误信息，请把窗口内容截图，
echo 或把 helper_error.txt 文件发给开发者。
echo.
powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -File "%PS1%" 2> "%WIN%helper_error.txt"
set "CODE=%ERRORLEVEL%"
echo.
echo ============ 运行结束 (退出码 %CODE%) ============
if exist "%WIN%helper_error.txt" (
    for %%A in ("%WIN%helper_error.txt") do if %%~zA GTR 0 (
        echo 捕获到的错误信息:
        echo.
        type "%WIN%helper_error.txt"
        echo.
        echo ============================================
    ) else (
        echo 没有捕获到错误信息（窗口停住=助手正常；秒关=其他原因）。
    )
) else (
    echo 没有生成错误文件（powershell 未能启动，多为路径问题）。
)
echo.
pause
