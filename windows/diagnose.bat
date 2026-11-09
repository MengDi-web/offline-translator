@echo off
chcp 936 >nul
set "WIN=%~dp0"
set "ROOT=%~dp0.."
echo ============================================
echo   miaomiao 诊断信息（请把整屏截图发给开发者）
echo ============================================
echo 程序目录: %ROOT%
echo.
echo [1] 关键文件检查
if exist "%ROOT%\server.js" (echo    server.js ........ OK) else (echo    server.js ........ 缺失! 目录不对?)
if exist "%ROOT%\neural\.venv\Scripts\python.exe" (echo    Python环境 ....... OK) else (echo    Python环境 ....... 缺失! 请先运行 install.cmd)
if exist "%ROOT%\neural\models\opus-mt-zh-en-ft\pytorch_model.bin" (echo    翻译模型 ....... OK) else (echo    翻译模型 ....... 缺失! 请先运行 install.cmd)
if exist "%ROOT%\data\common.json" (echo    词典数据 ....... OK) else (echo    词典数据 ....... 缺失!)
if exist "%WIN%\helper.log" (echo    helper.log ....... 存在) else (echo    helper.log ....... 不存在)
echo.
echo [2] 服务状态 (http://127.0.0.1:6688)
curl -s -m 3 http://127.0.0.1:6688/api/stats
echo.
echo.
echo [3] 启动划词助手（前台运行，错误会显示在下面）
echo     >>> 请按任意键开始 <<<
pause
powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -File "%WIN%\xuanci_helper.ps1"
echo.
echo ============================================
echo 划词助手已退出（或报错结束）。
echo 请把以上全部内容截图发给开发者。
echo ============================================
pause
