# open_window.ps1 — 等待翻译服务就绪后，用 Edge/Chrome 的「应用模式」弹出独立窗口
# （无地址栏、无标签页，看起来就是一个软件窗口；失败则回退为默认浏览器打开网页）

$ErrorActionPreference = 'SilentlyContinue'

# 1. 最多等 60 秒，直到服务就绪
$ready = $false
for ($i = 0; $i -lt 60; $i++) {
    try {
        $r = Invoke-WebRequest -Uri 'http://127.0.0.1:6688/api/stats' -UseBasicParsing -TimeoutSec 2
        if ($r.StatusCode -eq 200) { $ready = $true; break }
    } catch { }
    Start-Sleep -Seconds 1
}
if (-not $ready) { exit 1 }

$url = 'http://127.0.0.1:6688'
$args_app = "--app=$url --window-size=1120,800"

# 2. 找 Edge（Win10/11 自带）
$edge = Join-Path ${env:ProgramFiles(x86)} 'Microsoft\Edge\Application\msedge.exe'
if (-not (Test-Path $edge)) { $edge = Join-Path $env:ProgramFiles 'Microsoft\Edge\Application\msedge.exe' }
if (Test-Path $edge) {
    Start-Process -FilePath $edge -ArgumentList $args_app
    exit 0
}

# 3. 找 Chrome
$chrome = Join-Path $env:ProgramFiles 'Google\Chrome\Application\chrome.exe'
if (-not (Test-Path $chrome)) { $chrome = Join-Path ${env:ProgramFiles(x86)} 'Google\Chrome\Application\chrome.exe' }
if (Test-Path $chrome) {
    Start-Process -FilePath $chrome -ArgumentList $args_app
    exit 0
}

# 4. 都没有 → 默认浏览器打开网页
Start-Process $url
exit 0
