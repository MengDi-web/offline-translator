# diagnose.ps1 — 划词/翻译诊断（窗口不会闪退，结果全部显示在这里）
trap {
    Write-Host ''
    Write-Host ("诊断过程出错: " + $_.Exception.Message) -ForegroundColor Red
    Read-Host '按回车键关闭窗口'
    exit 1
}
$ErrorActionPreference = 'Continue'
$WIN  = Split-Path -Parent $MyInvocation.MyCommand.Path
$ROOT = Split-Path -Parent $WIN

Write-Host '============================================'
Write-Host '  miaomiao 诊断信息（请整屏截图给开发者）'
Write-Host '============================================'
Write-Host ("程序目录: " + $ROOT)
Write-Host ''

Write-Host '[1] 关键文件:'
function Chk([string]$name, [string]$path) {
    if (Test-Path -LiteralPath $path) { Write-Host ("  " + $name + " ... OK") }
    else { Write-Host ("  " + $name + " ... 缺失!") -ForegroundColor Red }
}
Chk 'server.js' (Join-Path $ROOT 'server.js')
$venvPy = Join-Path $ROOT 'neural\.venv\Scripts\python.exe'
$embedPy = Join-Path $ROOT 'runtime\python312\python.exe'
if ((Test-Path -LiteralPath $venvPy) -or (Test-Path -LiteralPath $embedPy)) {
    Write-Host '  Python环境 ... OK'
} else {
    Write-Host '  Python环境 ... 缺失!' -ForegroundColor Red
}
Chk '翻译模型' (Join-Path $ROOT 'neural\models\opus-mt-zh-en-ft\pytorch_model.bin')
Chk '词典数据' (Join-Path $ROOT 'data\common.json')
$log = Join-Path $WIN 'helper.log'
if (Test-Path -LiteralPath $log) {
    Write-Host '  helper.log ... 存在, 最近内容:'
    try { Get-Content -LiteralPath $log -Tail 15 | ForEach-Object { Write-Host ("    " + $_) } } catch {}
} else { Write-Host '  helper.log ... 不存在' }

Write-Host ''
Write-Host '[2] 服务状态:'
try {
    $s = Invoke-WebRequest -Uri 'http://127.0.0.1:6688/api/stats' -UseBasicParsing -TimeoutSec 3
    Write-Host ("  HTTP " + $s.StatusCode + "  " + $s.Content) -ForegroundColor Green
} catch { Write-Host '  服务未运行! 请先双击 start.bat' -ForegroundColor Red }

Write-Host ''
Write-Host '[3] 划词开关:'
try {
    $m = Invoke-WebRequest -Uri 'http://127.0.0.1:6688/api/selection-mode' -UseBasicParsing -TimeoutSec 3
    Write-Host ("  " + $m.Content) -ForegroundColor Green
} catch { Write-Host '  无法获取' }

Write-Host ''
Write-Host '[4] 启动划词助手(在当前窗口运行, 错误会显示在下面):'
Write-Host '    >>> 请按任意键开始 <<<'
$null = $Host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown')
& powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -File (Join-Path $WIN 'xuanci_helper.ps1')

Write-Host ''
Write-Host '============================================'
Write-Host '划词助手已退出。请把以上全部内容截图发给开发者。'
Write-Host '============================================'
Read-Host '按回车键关闭窗口'
