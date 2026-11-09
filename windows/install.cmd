@echo off
chcp 936 >nul
cd /d "%~dp0.."
if not exist "server.js" (
    echo [错误] 找不到翻译程序 server.js
    echo        你现在是在「压缩包里面」直接双击运行的，这样不行！
    echo        请先退出，右键压缩包选「全部解压」，
    echo        再进入解压出来的文件夹里的 windows 文件夹，运行本脚本。
    pause
    exit /b 1
)
echo ==============================================
echo   miaomiao翻译器 · 一键部署（只需运行一次）
echo   —— 自动准备 Node / Python / 翻译依赖 / 模型
echo ==============================================
echo.

REM ================= [1/5] Node =================
if exist "runtime\node\node.exe" goto NODE_OK
if exist "offline\node-v22.14.0-win-x64.zip" (
    echo [1/5] 使用内置便携版 Node.js（离线）
    copy /y "offline\node-v22.14.0-win-x64.zip" "%TEMP%\miaomiao-node.zip" >nul
) else (
    echo [1/5] 下载便携版 Node.js ...
    curl.exe -sfL --retry 3 --retry-all-errors -o "%TEMP%\miaomiao-node.zip" "https://nodejs.org/dist/v22.14.0/node-v22.14.0-win-x64.zip"
    if not exist "%TEMP%\miaomiao-node.zip" (
        echo       官方源失败，改用国内镜像...
        curl.exe -sfL --retry 3 --retry-all-errors -o "%TEMP%\miaomiao-node.zip" "https://registry.npmmirror.com/-/binary/node/v22.14.0/node-v22.14.0-win-x64.zip"
    )
    if not exist "%TEMP%\miaomiao-node.zip" (
        echo [错误] Node 下载失败（网络问题），请检查网络后重试
        pause & exit /b 1
    )
    echo        校验 SHA-256 ...
    certutil -hashfile "%TEMP%\miaomiao-node.zip" SHA256 | findstr /i "55b639295920b219bb2acbcfa00f90393a2789095b7323f79475c9f34795f217" >nul
    if errorlevel 1 (
        echo [错误] Node 校验失败（下载不完整或被篡改），请重试
        pause & exit /b 1
    )
)
powershell -NoProfile -Command "Expand-Archive '%TEMP%\miaomiao-node.zip' -DestinationPath 'runtime' -Force; if (Test-Path 'runtime\node-v22.14.0-win-x64') { Move-Item 'runtime\node-v22.14.0-win-x64' 'runtime\node' -Force }"
if not exist "runtime\node\node.exe" (
    echo [错误] Node 解压失败（可能被杀毒软件拦截或磁盘空间不足）
    echo        请检查杀毒软件/磁盘后重试
    pause & exit /b 1
)
:NODE_OK
del /q "%TEMP%\miaomiao-node.zip" >nul 2>&1
set "PATH=%CD%\runtime\node;%PATH%"
"runtime\node\node.exe" --version >nul 2>&1
if errorlevel 1 (
    echo [错误] Node 无法运行，请重新解压安装包后重试
    pause & exit /b 1
)
echo [1/5] Node 就绪

REM ================= [2/5] Python 3.12 x64 =================
REM 只认「Python 3.12 且 64 位」；装了 3.11/3.13/32位都视为不可用
set "PYEXE="
for /f "delims=" %%i in ('where python 2^>nul') do if not defined PYEXE set "PYEXE=%%i"
if defined PYEXE (
    "%PYEXE%" -c "import sys,struct;raise SystemExit(0 if sys.version_info[:2]==(3,12) and struct.calcsize('P')*8==64 else 1)" >nul 2>&1
    if errorlevel 1 (
        echo        检测到已装 Python 但不是 3.12 x64，将使用内置版本
        set "PYEXE="
    )
)
if defined PYEXE goto PY_OK
if exist "offline\python-3.12.0-amd64.exe" (
    echo [2/5] 安装内置 Python 3.12（离线，约 2 分钟）
    copy /y "offline\python-3.12.0-amd64.exe" "%TEMP%\miaomiao-python.exe" >nul
) else (
    echo [2/5] 下载并安装 Python 3.12 ...
    curl.exe -sfL --retry 3 --retry-all-errors -o "%TEMP%\miaomiao-python.exe" "https://www.python.org/ftp/python/3.12.0/python-3.12.0-amd64.exe"
    if not exist "%TEMP%\miaomiao-python.exe" (
        echo       官方源失败，改用国内镜像...
        curl.exe -sfL --retry 3 --retry-all-errors -o "%TEMP%\miaomiao-python.exe" "https://registry.npmmirror.com/-/binary/python/3.12.0/python-3.12.0-amd64.exe"
    )
    if not exist "%TEMP%\miaomiao-python.exe" (
        echo [错误] Python 下载失败（网络问题），请检查网络后重试
        pause & exit /b 1
    )
    echo        校验 SHA-256 ...
    certutil -hashfile "%TEMP%\miaomiao-python.exe" SHA256 | findstr /i "c6bdf93f4b2de6dfa1a3a847e7c24ae10edf7f6318653d452cd4381415700ada" >nul
    if errorlevel 1 (
        echo [错误] Python 校验失败（下载不完整或被篡改），请重试
        pause & exit /b 1
    )
)
"%TEMP%\miaomiao-python.exe" /quiet InstallAllUsers=0 PrependPath=1 Include_test=0 Include_doc=0
del /q "%TEMP%\miaomiao-python.exe" >nul 2>&1
set "PYEXE=%LocalAppData%\Programs\Python\Python312\python.exe"
set "PATH=%LocalAppData%\Programs\Python\Python312;%LocalAppData%\Programs\Python\Python312\Scripts;%PATH%"
:PY_OK
if not exist "%PYEXE%" (
    echo [错误] 找不到可用的 Python 3.12
    pause & exit /b 1
)
"%PYEXE%" -c "import sys,struct;raise SystemExit(0 if sys.version_info[:2]==(3,12) and struct.calcsize('P')*8==64 else 1)" >nul 2>&1
if errorlevel 1 (
    echo [错误] Python 不是 3.12 64 位，无法继续
    pause & exit /b 1
)
echo [2/5] Python 就绪

REM ================= [3/5] 翻译环境 + 依赖 =================
REM 已有 venv 但不是 3.12 x64 → 删除重建
if exist "neural\.venv\Scripts\python.exe" (
    neural\.venv\Scripts\python -c "import sys,struct;raise SystemExit(0 if sys.version_info[:2]==(3,12) and struct.calcsize('P')*8==64 else 1)" >nul 2>&1
    if errorlevel 1 (
        echo        已有环境版本不符，正在重建...
        rmdir /s /q "neural\.venv"
    )
)
if not exist "neural\.venv\Scripts\python.exe" (
    echo [3/5] 创建翻译环境并安装依赖（约 5-10 分钟，请耐心等待）
    "%PYEXE%" -m venv neural\.venv
    if not exist "neural\.venv\Scripts\python.exe" (
        echo [错误] 创建虚拟环境失败
        pause & exit /b 1
    )
    if exist "wheels" (
        echo        使用内置依赖包（离线安装）
        neural\.venv\Scripts\python -m pip install --no-index --find-links "wheels" torch transformers sentencepiece sacrebleu numpy
    ) else (
        neural\.venv\Scripts\python -m pip install --upgrade pip -q
        neural\.venv\Scripts\python -m pip install -q torch --index-url https://download.pytorch.org/whl/cpu
        neural\.venv\Scripts\python -m pip install -q transformers sentencepiece sacrebleu numpy
    )
) else (
    echo [3/5] 翻译环境已存在，校验依赖...
)
REM 关键验收：真正 import 一次（能发现缺 VC++ 运行库等问题）
neural\.venv\Scripts\python -c "import torch, transformers, sentencepiece, numpy" >nul 2>&1
if errorlevel 1 (
    echo.
    echo [错误] 翻译依赖无法加载，神经翻译不可用。
    echo        最常见原因：缺少微软 VC++ 运行库。
    echo        请双击安装包内 offline\vc_redist.x64.exe（需管理员确认，一次即可），
    echo        安装完成后重新运行本脚本。
    echo        若仍失败：删除 neural\.venv 文件夹后重新运行本脚本。
    pause & exit /b 1
)
echo [3/5] 依赖就绪

REM ================= [4/5] 翻译模型 =================
set "NEED_MODEL="
if not exist "neural\models\opus-mt-zh-en-ft\pytorch_model.bin" set "NEED_MODEL=1"
if not exist "neural\models\opus-mt-en-zh-ft\pytorch_model.bin" set "NEED_MODEL=1"
if not defined NEED_MODEL goto MODEL_OK
echo [4/5] 下载翻译模型（约 300MB，1-5 分钟）
node tools\fetch-models.js
if errorlevel 1 (
    echo [错误] 模型下载失败（网络问题或 Release 不可用），请重试
    pause & exit /b 1
)
:MODEL_OK
if not exist "neural\models\opus-mt-zh-en-ft\pytorch_model.bin" (
    echo [错误] 中文→英文模型缺失
    pause & exit /b 1
)
if not exist "neural\models\opus-mt-en-zh-ft\pytorch_model.bin" (
    echo [错误] 英文→中文模型缺失
    pause & exit /b 1
)
echo [4/5] 模型就绪

REM ================= [5/5] 词典数据 =================
if not exist "data\common.json" (
    echo [5/5] 生成词典数据 ...
    node tools\fetch-data.js
    if errorlevel 1 (
        echo [错误] 词典数据生成失败
        pause & exit /b 1
    )
    node tools\build-index.js
    if errorlevel 1 (
        echo [错误] 词典索引生成失败
        pause & exit /b 1
    )
) else (
    echo [5/5] 词典已就绪
)
if not exist "data\common.json" (
    echo [错误] 词典数据缺失
    pause & exit /b 1
)

echo.
echo ==============================================
echo   部署完成！以后每次使用：双击 start.bat
echo   然后浏览器地址栏输入 http://127.0.0.1:6688
echo ==============================================
pause
