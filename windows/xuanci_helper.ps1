﻿﻿﻿﻿# xuanci_helper.ps1 — Windows miaomiao翻译助手（Cmd+C 触发，PowerShell 原生，无需编译）
#
# 用法:
#   powershell.exe -ExecutionPolicy Bypass -File xuanci_helper.ps1
# 依赖:
#   - 翻译服务已在运行: node server.js  (http://127.0.0.1:6688)
#   - PowerShell 5.1+ (Windows 10/11 自带; 必须是 powershell.exe 而非 pwsh, 需要 STA)
#
# 功能: 复制(Cmd+C)即弹窗翻译; 菜单栏托盘图标可开设置/退出;
#       设置: 弹窗宽度/划词字号/翻译字号/背景色/背景透明度/复制键色/关闭键色/圆角

param([switch]$Debug)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$SCRIPT_DIR = Split-Path -Parent $MyInvocation.MyCommand.Path
$CONFIG_PATH = Join-Path $SCRIPT_DIR 'xuanci_config.json'
$SERVER = 'http://127.0.0.1:6688/api/context-translate'

# ---------- 默认配置 ----------
$DEFAULTS = @{
    width = 380
    origFontSize = 15
    transFontSize = 14
    opacity = 0.98
    radius = 12
    bgColor = '#FBF6EC'    # 苹果米黄
    copyColor = '#FF3B30'  # 苹果红
    closeColor = '#A89E8B'
    origColor = '#1D1D1F'
    transColor = '#E5352B'
}

function Load-Config {
    if (Test-Path $CONFIG_PATH) {
        try {
            $j = Get-Content $CONFIG_PATH -Raw -Encoding UTF8 | ConvertFrom-Json
            $cfg = @{}
            foreach ($k in $DEFAULTS.Keys) { $cfg[$k] = if ($null -ne $j.$k) { $j.$k } else { $DEFAULTS[$k] } }
            return $cfg
        } catch {}
    }
    return $DEFAULTS.Clone()
}
function Save-Config($cfg) {
    $j = [ordered]@{}
    foreach ($k in $DEFAULTS.Keys) { $j[$k] = $cfg[$k] }
    $j | ConvertTo-Json | Set-Content -Path $CONFIG_PATH -Encoding UTF8
}

$cfg = Load-Config

function HexToColor($hex) {
    try {
        return [System.Drawing.ColorTranslator]::FromHtml($hex)
    } catch { return [System.Drawing.Color]::FromArgb(26,26,26) }
}
function ToHexColor($c) {
    return ('#{0:X2}{1:X2}{2:X2}' -f $c.R, $c.G, $c.B)
}

# ---------- PDF 断行归一化 ----------
function Normalize-Wrapped($text) {
    $parts = $text -split "?
?
+"
    $out = @()
    foreach ($p in $parts) {
        $lines = $p -split "?
"
        if ($lines.Count -le 1) { $out += $p; continue }
        $sb = $lines[0]
        for ($i = 1; $i -lt $lines.Count; $i++) {
            $prevLast = $lines[$i-1].Substring($lines[$i-1].Length - 1, 1)
            $curFirst = $lines[$i].Substring(0, 1)
            if ($prevLast -match '[。！？!?；;""…]') {
                $sb += "`n"
            } else {
                $cjkP = $prevLast -match '[㐀-鿿]'
                $cjkC = $curFirst -match '[㐀-鿿]'
                if (-not ($cjkP -and $cjkC)) { $sb += ' ' }
            }
            $sb += $lines[$i]
        }
        $out += $sb
    }
    return ($out -join "`r`n`r`n")
}

# ---------- 乱码检测 ----------
function Test-Garbled($text) {
    if ($text.Length -lt 4) { return $false }
    if ($text -match '(.)\1{9,}') { return $true }
    $bad = ([regex]::Matches($text, '[{}[\]|~^`\\<>=-]')).Count
    if (($bad / $text.Length) -gt 0.3) { return $true }
    if ($text.Length -ge 16 -and (($text.ToCharArray() | Select-Object -Unique).Count) -le 2) { return $true }
    return $false
}

# ---------- 翻译请求 ----------
function Request-Translation($text) {
    $body = @{ selection = $text; context = '' } | ConvertTo-Json -Compress
    # PowerShell 5.1 的字符串 Body 默认按 ASCII 编码，中文会乱码 → 必须转 UTF-8 字节
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($body)
    try {
        $resp = Invoke-RestMethod -Uri $SERVER -Method Post -Body $bytes -ContentType 'application/json; charset=utf-8' -TimeoutSec 60
        return $resp
    } catch {
        return $null
    }
}

# ---------- 弹窗 ----------
$popupForm = $null
$script:dragState = @{ dragging = $false; dx = 0; dy = 0 }
$lastCopyText = ''
$lastCopyTime = [DateTime]::MinValue

function Show-Popup($resp) {
    if ($popupForm -and -not $popupForm.IsDisposed) { $popupForm.Close() }

    $f = New-Object System.Windows.Forms.Form
    $f.FormBorderStyle = 'None'
    $f.StartPosition = 'Manual'
    $f.ShowInTaskbar = $false
    $f.TopMost = $true
    $f.BackColor = HexToColor $cfg.bgColor
    $f.Opacity = [double]$cfg.opacity

    $title = New-Object System.Windows.Forms.Label
    $title.AutoSize = $false
    $title.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', [float]$cfg.origFontSize, [System.Drawing.FontStyle]::Bold)
    $title.ForeColor = HexToColor $cfg.origColor
    $title.Padding = New-Object System.Windows.Forms.Padding(14,10,14,0)
    $title.AutoEllipsis = $true

    $bodyLbl = New-Object System.Windows.Forms.Label
    $bodyLbl.AutoSize = $false
    $bodyLbl.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', [float]$cfg.transFontSize)
    $bodyLbl.ForeColor = HexToColor $cfg.transColor
    $bodyLbl.Padding = New-Object System.Windows.Forms.Padding(14,6,14,0)
    $bodyLbl.AutoEllipsis = $true

    $copyBtn = New-Object System.Windows.Forms.Button
    $copyBtn.Text = '复制译文'
    $copyBtn.FlatStyle = 'Flat'
    $copyBtn.BackColor = HexToColor $cfg.copyColor
    $copyBtn.ForeColor = [System.Drawing.Color]::White
    $copyBtn.FlatAppearance.BorderSize = 0
    $copyBtn.Cursor = 'Hand'

    $settingsBtn = New-Object System.Windows.Forms.Button
    $settingsBtn.Text = '设置'
    $settingsBtn.FlatStyle = 'Flat'
    $settingsBtn.BackColor = HexToColor $cfg.copyColor
    $settingsBtn.ForeColor = [System.Drawing.Color]::White
    $settingsBtn.FlatAppearance.BorderSize = 0
    $settingsBtn.Cursor = 'Hand'
    $settingsBtn.Add_Click({ Show-Settings })

    $closeBtn = New-Object System.Windows.Forms.Button
    $closeBtn.Text = '✕'
    $closeBtn.FlatStyle = 'Flat'
    $closeBtn.BackColor = HexToColor $cfg.closeColor
    $closeBtn.ForeColor = [System.Drawing.Color]::White
    $closeBtn.FlatAppearance.BorderSize = 0
    $closeBtn.Cursor = 'Hand'

    $script:copyPayload = ''
    if ($resp.error) {
        $title.Text = '⚠ 提示'
        $bodyLbl.Text = $resp.error
    } else {
        $completed = [string]$resp.completed
        $head = if ($completed.Length -gt 80) { $completed.Substring(0,80) + '…' } else { $completed }
        $title.Text = $head
        if ($resp.changed) {
            $title.Text += "`n(已补齐: $($resp.original) → $completed)"
            $title.Height = 70
        }
        if ($resp.kind -eq 'sentence') {
            $bodyLbl.Text = [string]$resp.translation
            $script:copyPayload = [string]$resp.translation
        } else {
            if ($resp.translation) { $bodyLbl.Text = [string]$resp.translation; $script:copyPayload = [string]$resp.translation }
            elseif ($resp.bestSense.sense) { $bodyLbl.Text = '● ' + $resp.bestSense.sense; $script:copyPayload = [string]$resp.bestSense.sense }
            elseif ($resp.dictSenses) { $bodyLbl.Text = ($resp.dictSenses -join '  |  '); $script:copyPayload = ($resp.dictSenses -join ' | ') }
            if ($resp.contextTranslation) { $bodyLbl.Text += "`n语境: $($resp.contextTranslation)" }
        }
    }

    $copyBtn.Add_Click({
        if ($script:copyPayload) {
            [System.Windows.Forms.Clipboard]::SetText($script:copyPayload)
            $copyBtn.Text = '已复制 ✓'
            Start-Sleep -Milliseconds 1200
            $copyBtn.Text = '复制译文'
        }
    })
    $closeBtn.Add_Click({ $f.Close() })

    # 拖拽移动：按住窗体/标题/正文拖动（按钮除外，保持可点击）
    $dragTargets = @($f, $title, $bodyLbl)
    foreach ($ctrl in $dragTargets) {
        $ctrl.Add_MouseDown({
            param($s, $e)
            if ($e.Button -eq 'Left') {
                $script:dragState.dragging = $true
                $script:dragState.dx = $e.X
                $script:dragState.dy = $e.Y
            }
        })
        $ctrl.Add_MouseMove({
            param($s, $e)
            if ($script:dragState.dragging -and $script:popupForm) {
                $f2 = $script:popupForm
                $f2.Location = New-Object System.Drawing.Point(
                    ($f2.Location.X + $e.X - $script:dragState.dx),
                    ($f2.Location.Y + $e.Y - $script:dragState.dy))
            }
        })
        $ctrl.Add_MouseUp({ $script:dragState.dragging = $false })
    }

    $f.Controls.Add($title)
    $f.Controls.Add($bodyLbl)
    $f.Controls.Add($copyBtn)
    $f.Controls.Add($settingsBtn)
    $f.Controls.Add($closeBtn)

    # 布局
    $w = [int]$cfg.width
    $title.Width = $w - 28
    $bodyLbl.Width = $w - 28
    $title.Top = 0; $title.Left = 0
    $bodyLbl.Top = $title.Height; $bodyLbl.Left = 0
    $bodyLbl.Height = [Math]::Min(360, [Math]::Max(40, [int]($bodyLbl.PreferredHeight + 12)))
    $f.ClientSize = New-Object System.Drawing.Size($w, $bodyLbl.Bottom + 40)
    $copyBtn.SetBounds(14, $bodyLbl.Bottom + 6, 90, 28)
    $settingsBtn.SetBounds(110, $bodyLbl.Bottom + 6, 64, 28)
    $closeBtn.SetBounds($w - 46, $bodyLbl.Bottom + 6, 32, 28)

    # 圆角（WinForms 原生不支持，这里用 Region 近似）
    if ($cfg.radius -gt 0) {
        $path = New-Object System.Drawing.Drawing2D.GraphicsPath
        $d = [Math]::Min([int]$cfg.radius, 24) * 2
        $rect = New-Object System.Drawing.Rectangle(0,0,$f.Width,$f.Height)
        $path.AddArc($rect.X, $rect.Y, $d, $d, 180, 90)
        $path.AddArc($rect.Right - $d, $rect.Y, $d, $d, 270, 90)
        $path.AddArc($rect.Right - $d, $rect.Bottom - $d, $d, $d, 0, 90)
        $path.AddArc($rect.X, $rect.Bottom - $d, $d, $d, 90, 90)
        $path.CloseFigure()
        $f.Region = New-Object System.Drawing.Region($path)
    }

    # 位置：鼠标下方
    $pos = [System.Windows.Forms.Cursor]::Position
    $screen = [System.Windows.Forms.Screen]::FromPoint($pos)
    $x = $pos.X - 12
    $y = $pos.Y + 14
    if ($x + $w -gt $screen.WorkingArea.Right) { $x = $screen.WorkingArea.Right - $w - 8 }
    if ($x -lt $screen.WorkingArea.Left) { $x = $screen.WorkingArea.Left + 8 }
    if ($y + $f.Height -gt $screen.WorkingArea.Bottom) { $y = $pos.Y - $f.Height - 10 }
    $f.Location = New-Object System.Drawing.Point($x, $y)

    $popupForm = $f
    $f.Show()
    $f.BringToFront()
}

# ---------- 剪贴板监听（STA 必需；用 add_Tick 同 runspace 处理，避免跨会话作用域问题） ----------
$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 250
$timer.add_Tick({
    try {
        if (-not [System.Windows.Forms.Clipboard]::ContainsText()) { return }
        $t = Normalize-Wrapped ([System.Windows.Forms.Clipboard]::GetText())
        if ([string]::IsNullOrWhiteSpace($t)) { return }
        $now = [DateTime]::Now
        if ($t -eq $script:lastText -and ($now - $script:lastCopyTime).TotalSeconds -lt 2) { return }
        if (Test-Garbled $t) {
            Show-Popup @{ error = '⚠ 复制内容疑似乱码（可能来自应用的复制保护），无法翻译' }
            $script:lastText = $t; $script:lastCopyTime = $now
            return
        }
        $resp = Request-Translation $t
        if ($resp) {
            Show-Popup $resp
        } else {
            Show-Popup @{ error = '翻译服务未运行，请先启动: node server.js' }
        }
        $script:lastText = $t; $script:lastCopyTime = $now
    } catch {}
})
$script:lastText = ''
$script:lastCopyTime = [DateTime]::MinValue
$timer.Start()

# ---------- 设置窗口 ----------
function Show-Settings {
    $sf = New-Object System.Windows.Forms.Form
    $sf.Text = 'miaomiao翻译器 · 设置'
    $sf.FormBorderStyle = 'FixedDialog'
    $sf.StartPosition = 'CenterScreen'
    $sf.ClientSize = New-Object System.Drawing.Size(360, 340)

    function Add-Slider($parent, $y, $labelText, $min, $max, $value, $tag) {
        $lbl = New-Object System.Windows.Forms.Label
        $lbl.Text = $labelText; $lbl.SetBounds(14, $y, 90, 22)
        $trk = New-Object System.Windows.Forms.TrackBar
        $trk.SetBounds(110, $y, 170, 30)
        $trk.Minimum = $min; $trk.Maximum = $max; $trk.Value = $value
        $val = New-Object System.Windows.Forms.Label
        $val.Text = "$value"; $val.SetBounds(290, $y, 50, 22)
        $trk.Add_ValueChanged({ $val.Text = "$($trk.Value)" })
        $parent.Controls.Add($lbl); $parent.Controls.Add($trk); $parent.Controls.Add($val)
        return $trk
    }

    $trkWidth = Add-Slider $sf 10 '弹窗宽度' 260 560 $cfg.width 'width'
    $trkOrig = Add-Slider $sf 48 '划词字号' 10 24 $cfg.origFontSize 'origFontSize'
    $trkTrans = Add-Slider $sf 86 '翻译字号' 10 24 $cfg.transFontSize 'transFontSize'
    $trkOpacity = Add-Slider $sf 124 '背景透明度' 30 100 ([int]($cfg.opacity*100)) 'opacity'
    $trkRadius = Add-Slider $sf 162 '圆角弧度' 0 28 $cfg.radius 'radius'

    function Add-ColorBtn($parent, $y, $labelText, $colorKey) {
        $lbl = New-Object System.Windows.Forms.Label
        $lbl.Text = $labelText; $lbl.SetBounds(14, $y, 90, 24)
        $btn = New-Object System.Windows.Forms.Button
        $btn.Text = '选择颜色'; $btn.SetBounds(110, $y, 100, 26)
        $btn.BackColor = HexToColor $cfg[$colorKey]
        $btn.Add_Click({
            $dlg = New-Object System.Windows.Forms.ColorDialog
            $dlg.Color = HexToColor $cfg[$colorKey]
            if ($dlg.ShowDialog() -eq 'OK') {
                $btn.BackColor = $dlg.Color
                $cfg[$colorKey] = ToHexColor $dlg.Color
                Save-Config $cfg
            }
        })
        $parent.Controls.Add($lbl); $parent.Controls.Add($btn)
    }
    Add-ColorBtn $sf 200 '背景颜色' 'bgColor'
    Add-ColorBtn $sf 234 '复制键颜色' 'copyColor'
    Add-ColorBtn $sf 268 '关闭键颜色' 'closeColor'

    $okBtn = New-Object System.Windows.Forms.Button
    $okBtn.Text = '保存'; $okBtn.SetBounds(280, 306, 64, 26)
    $okBtn.Add_Click({
        $cfg.width = $trkWidth.Value
        $cfg.origFontSize = $trkOrig.Value
        $cfg.transFontSize = $trkTrans.Value
        $cfg.opacity = ($trkOpacity.Value / 100.0)
        $cfg.radius = $trkRadius.Value
        Save-Config $cfg
        $sf.Close()
    })
    $sf.Controls.Add($okBtn)
    $sf.Show()
}

# ---------- 托盘图标 ----------
$notify = New-Object System.Windows.Forms.NotifyIcon
$notify.Icon = [System.Drawing.SystemIcons]::Information
$notify.Text = 'miaomiao翻译助手'
$notify.Visible = $true
$menu = New-Object System.Windows.Forms.ContextMenuStrip
$itemSettings = $menu.Items.Add('设置…')
$itemExit = $menu.Items.Add('退出')
$notify.ContextMenuStrip = $menu
$itemSettings.Add_Click({ Show-Settings })
$itemExit.Add_Click({ $timer.Stop(); $notify.Visible = $false; [System.Windows.Forms.Application]::Exit() })

Write-Host 'miaomiao翻译助手已启动 —— 选中文字后按 Ctrl+C（复制）即弹窗翻译'
Write-Host '右键托盘图标可设置/退出'

# 保持消息循环
[System.Windows.Forms.Application]::Run()
