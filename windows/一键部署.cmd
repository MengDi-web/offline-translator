@echo off
chcp 936 >nul
cd /d "%~dp0.."
echo ==============================================
echo   miaomiao翻译器 · 一键部署（只需运行一次）
echo   —— 自动准备 Node、Python、模型，之后免操作
echo ==============================================
echo.

REM ---------- 1. 便携版 Node ----------
if not exist "runtime\node\node.exe" (
    echo [1/4] 下载便携版 Node.js ...
    powershell -NoProfile -Command "Invoke-WebRequest -Uri 'https://nodejs.org/dist/v22.14.0/node-v22.14.0-win-x64.zip' -OutFile '%TEMP%\miaomiao-node.zip'; Expand-Archive '%TEMP%\miaomiao-node.zip' -DestinationPath 'runtime' -Force; if (Test-Path 'runtime\node-v22.14.0-win-x64') { Move-Item 'runtime\node-v22.14.0-win-x64' 'runtime\node' -Force }"
) else (
    echo [1/4] Node 已就绪
)
set "PATH=%CD%\runtime\node;%PATH%"

REM ---------- 2. Python（未安装则静默安装） ----------
python --version >nul 2>&1
if errorlevel 1 (
    echo [2/4] 未检测到 Python，正在下载并静默安装（约 3 分钟，无需操作）...
    powershell -NoProfile -Command "Invoke-WebRequest -Uri 'https://www.python.org/ftp/python/3.12.0/python-3.12.0-amd64.exe' -OutFile '%TEMP%\miaomiao-python.exe'"
    "%TEMP%\miaomiao-python.exe" /quiet InstallAllUsers=0 PrependPath=1 Include_test=0 Include_doc=0
    rem 刷新 PATH
    set "PATH=%LocalAppData%\Programs\Python\Python312;%LocalAppData%\Programs\Python\Python312\Scripts;%PATH%"
) else (
    echo [2/4] Python 已就绪
)

REM ---------- 3. Python 环境 + 神经依赖 ----------
if not exist "neural\.venv\Scripts\python.exe" (
    echo [3/4] 创建翻译环境并安装依赖（首次约 5-10 分钟，请耐心等待）...
    python -m venv neural\.venv
    neural\.venv\Scripts\python -m pip install --upgrade pip -q
    neural\.venv\Scripts\pip install -q torch --index-url https://download.pytorch.org/whl/cpu
    neural\.venv\Scripts\pip install -q transformers sentencepiece sacrebleu numpy
) else (
    echo [3/4] 翻译环境已就绪
)

REM ---------- 4. 翻译模型 ----------
if not exist "neural\models\opus-mt-zh-en-ft\pytorch_model.bin" (
    echo [4/4] 下载翻译模型（约 300MB，视网速 1-5 分钟）...
    node tools\fetch-models.js
) else (
    echo [4/4] 模型已就绪
)

REM ---------- 5. 词典数据 ----------
if not exist "data\common.json" (
    echo [5/5] 生成词典数据 ...
    node tools\fetch-data.js
    node tools\build-index.js
) else (
    echo [5/5] 词典已就绪
)

echo.
echo ==============================================
echo   部署完成！以后只需双击 启动翻译器.bat
echo   （划词：选中文字 → Ctrl+C）
echo ==============================================
pause
