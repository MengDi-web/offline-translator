# make_shortcut.ps1 — 在桌面创建带图标的「miaomiao翻译器」快捷方式
$ErrorActionPreference = 'Stop'
$WIN  = Split-Path -Parent $MyInvocation.MyCommand.Path
$ROOT = Split-Path -Parent $WIN
$target = Join-Path $WIN 'start.bat'
$icon   = Join-Path $WIN 'miaomiao.ico'
$desk   = [Environment]::GetFolderPath('Desktop')
$lnk    = Join-Path $desk 'miaomiao翻译器.lnk'

$ws = New-Object -ComObject WScript.Shell
$s = $ws.CreateShortcut($lnk)
$s.TargetPath = $target
$s.WorkingDirectory = $ROOT
if (Test-Path $icon) { $s.IconLocation = $icon }
$s.Description = 'miaomiao翻译器 - 离线中英互译'
$s.WindowStyle = 7   # 最小化运行(服务在托盘)
$s.Save()

Write-Host ''
Write-Host '✅ 已创建桌面快捷方式: miaomiao翻译器' -ForegroundColor Green
Write-Host '   双击它即可启动（黑色窗口最小化，右下角托盘有图标）'
Write-Host '   想换图标: 右键快捷方式 → 属性 → 更改图标'
