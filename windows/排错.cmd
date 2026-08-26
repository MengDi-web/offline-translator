@echo off
chcp 936 >nul
cd /d "%~dp0.."
echo ============================================
echo   miaomiao翻译器 · 划词助手排错工具
echo   作用: 启动助手并把任何错误写入
echo         windows\helper_error.txt
echo ============================================
echo.
echo 如果下面出现错误信息，请把窗口内容截图，
echo 或把 windows\helper_error.txt 文件发给开发者。
echo.
powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -File "windows\xuanci_helper.ps1" 2> "windows\helper_error.txt"
set "CODE=%ERRORLEVEL%"
echo.
echo ============ 运行结束 (退出码 %CODE%) ============
if exist "windows\helper_error.txt" (
    for %%A in ("windows\helper_error.txt") do if %%~zA GTR 0 (
        echo 捕获到的错误信息:
        echo.
        type "windows\helper_error.txt"
        echo.
        echo ============================================
    ) else (
        echo 没有捕获到错误信息（窗口停住=助手正常；秒关=其他原因）。
    )
)
echo.
pause
