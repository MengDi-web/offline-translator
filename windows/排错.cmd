@echo off
chcp 936 >nul
set "WIN=%~dp0"
if not exist "%WIN%xuanci_helper.ps1" (
    echo [错误] 找不到 xuanci_helper.ps1
    echo        排错.cmd 必须和 xuanci_helper.ps1 在同一个 windows 文件夹里
    pause
    exit /b 1
)
echo ============================================
echo   miaomiao翻译器 · 划词助手排错工具
echo   作用: 启动助手并把任何错误写入
echo         %WIN%helper_error.txt
echo ============================================
echo.
echo 如果下面出现错误信息，请把窗口内容截图，
echo 或把 helper_error.txt 文件发给开发者。
echo.
powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -File "%WIN%xuanci_helper.ps1" 2> "%WIN%helper_error.txt"
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
