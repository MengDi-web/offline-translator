# xuanci_helper.ps1 — Windows miaomiao翻译助手（Cmd+C 触发，PowerShell 原生，无需编译）
#
# 用法:
#   powershell.exe -ExecutionPolicy Bypass -File xuanci_helper.ps1
# 依赖:
#   - 翻译服务已在运行: node server.js  (http://127.0.0.1:6688)
#   - PowerShell 5.1+ (Windows 10/11 自带; 必须是 powershell.exe 而非 pwsh, 需要 STA)
#
# 功能: 复制(Cmd+C)即弹窗翻译; 菜单栏托盘图标可开设置/退出;
#       设置: 弹窗宽度/划词字号/翻译字号/圆角/背景色/复制键色/关闭键色/原文字色/译文文字色

param([switch]$Debug)

# 启动失败兜底：显示错误并停留，避免窗口闪退看不到原因
trap {
    try { Log ("启动失败(错误): " + $_.Exception.Message + " | " + $_.InvocationInfo.PositionMessage) } catch {}
    Write-Host ''
    Write-Host '=================================================='
    Write-Host "启动失败: $_"
    Write-Host '请把上面的错误信息发给开发者'
    Write-Host '=================================================='
    Read-Host '按回车键关闭窗口'
    exit 1
}

# ---------- 运行日志（windows\helper.log，排错用） ----------
$SCRIPT_DIR = Split-Path -Parent $MyInvocation.MyCommand.Path
$LOG = Join-Path $SCRIPT_DIR 'helper.log'
function Log($msg) {
    try { Add-Content -Path $LOG -Value ("[{0}] {1}" -f (Get-Date -Format 'HH:mm:ss'), $msg) -Encoding UTF8 } catch {}
}
$SCRIPT_VERSION = 'win-v3 (2026-11 脚本作用域修复)'
Log "=== 启动 PID=$PID 版本=$SCRIPT_VERSION ==="

# 单实例互斥锁: 防止重复启动导致双弹窗/循环翻译
$singletonMutex = New-Object System.Threading.Mutex($false, 'MiaomiaoXuanciHelper')
if (-not $singletonMutex.WaitOne(0)) {
    Log "已有实例在运行, 本次退出"
    Write-Host '划词助手已在运行（请看系统托盘图标），无需重复启动'
    Start-Sleep -Seconds 2
    exit 1
}

$ErrorActionPreference = 'Stop'
Log "加载 WinForms..."
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
# 剪贴板序列号: 每次"复制"都会 +1, 用于区分"重新复制了同样的文字"
try {
    Add-Type -Namespace MiaoNative -Name Clip -MemberDefinition @'
[DllImport("user32.dll")] public static extern uint GetClipboardSequenceNumber();
'@
    Log "剪贴板序列号 API 就绪"
} catch { Log ("剪贴板序列号 API 失败: " + $_.Exception.Message) }
Log "WinForms 就绪"

$CONFIG_PATH = Join-Path $SCRIPT_DIR 'xuanci_config.json'
$SERVER = 'http://127.0.0.1:6688/api/context-translate'

# ---------- 默认配置 ----------
$DEFAULTS = @{
    version = 3              # 配色版本: 3
    followTheme = $true      # 弹窗颜色跟随页面主题
    width = 350
    origFontSize = 14
    transFontSize = 15
    opacity = 0.98
    radius = 16
    bgColor = '#FFFDF7'      # 页面卡片米白
    copyColor = '#FF3B30'    # 苹果红按键
    closeColor = '#F0EAE0'   # 淡灰关闭键
    origColor = '#1D1D1F'    # 深色原文
    transColor = '#1D1D1F'   # 与页面正文同色
}

function Load-Config {
    if (Test-Path $CONFIG_PATH) {
        try {
            $j = Get-Content $CONFIG_PATH -Raw -Encoding UTF8 | ConvertFrom-Json
            # 旧版配色(version<2)直接重置, 保证首次看到的是与页面一致的主题
            if ($j.version -ne 3) { return $DEFAULTS.Clone() }
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
    $json = $j | ConvertTo-Json
    # 必须无 BOM: 否则 server.js 的 JSON.parse 会失败(网页设置页读不到)
    [System.IO.File]::WriteAllText($CONFIG_PATH, $json, (New-Object System.Text.UTF8Encoding($false)))
}

$cfg = Load-Config
Log ("启动 PID=$PID")

function HexToColor($hex) {
    try {
        return [System.Drawing.ColorTranslator]::FromHtml($hex)
    } catch { return [System.Drawing.Color]::FromArgb(26,26,26) }
}
function ToHexColor($c) {
    return ('#{0:X2}{1:X2}{2:X2}' -f $c.R, $c.G, $c.B)
}
# 按背景亮度选择文字颜色, 避免白字+浅底看不清
function Get-ContrastText($bg) {
    $lum = 0.299 * $bg.R + 0.587 * $bg.G + 0.114 * $bg.B
    if ($lum -gt 150) { return [System.Drawing.Color]::FromArgb(50, 45, 40) }
    return [System.Drawing.Color]::White
}

# ---------- PDF 断行归一化 ----------
function Normalize-Wrapped($text) {
    # PDF 断行归一化：段落按空行切分（兼容 CRLF 与 LF）
    $parts = $text -split '\r?\n(\r?\n)+'
    $out = @()
    foreach ($p in $parts) {
        $lines = $p -split '\r?\n'
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
    return ($out -join "`n`n")
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
    # 每次弹窗前重新读配置: 网页版设置页修改后即时生效
    try { $script:cfg = Load-Config } catch {}
    # 颜色跟随页面主题(服务端在响应里带了 themePalette)
    if ($cfg.followTheme -ne $false -and $resp.themePalette) {
        $pal = $resp.themePalette
        if ($pal.bgColor)    { $cfg.bgColor = [string]$pal.bgColor }
        if ($pal.origColor)  { $cfg.origColor = [string]$pal.origColor }
        if ($pal.transColor) { $cfg.transColor = [string]$pal.transColor }
        if ($pal.copyColor)  { $cfg.copyColor = [string]$pal.copyColor }
        if ($pal.closeColor) { $cfg.closeColor = [string]$pal.closeColor }
        if ($pal.borderColor) { $script:borderColor = [string]$pal.borderColor }
    }
    if ($popupForm -and -not $popupForm.IsDisposed) { $popupForm.Close() }

    $f = New-Object System.Windows.Forms.Form
    $f.FormBorderStyle = 'None'
    $f.StartPosition = 'Manual'
    $f.ShowInTaskbar = $false
    $f.TopMost = $true
    $f.BackColor = HexToColor $cfg.bgColor
    $f.Opacity = 1.0   # WinForms Opacity 会让文字一起变淡, 故固定不透明

    $title = New-Object System.Windows.Forms.Label
    $title.AutoSize = $false
    $title.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', [float]$cfg.origFontSize, [System.Drawing.FontStyle]::Bold)
    $title.Height = [int][Math]::Ceiling($title.Font.GetHeight()) + 16   # 修复原文只显示上半部分
    $title.ForeColor = HexToColor $cfg.origColor
    $title.Padding = New-Object System.Windows.Forms.Padding(14,10,14,0)
    $title.AutoEllipsis = $true

    # 正文: 多行只读文本框(最多 6 行, 超出可滚动)
    $bodyLbl = New-Object System.Windows.Forms.TextBox
    $bodyLbl.Multiline = $true
    $bodyLbl.ReadOnly = $true
    $bodyLbl.BorderStyle = 'None'
    $bodyLbl.ScrollBars = 'Vertical'
    $bodyLbl.WordWrap = $true
    $bodyLbl.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', [float]$cfg.transFontSize)
    $bodyLbl.BackColor = HexToColor $cfg.bgColor
    $bodyLbl.ForeColor = HexToColor $cfg.transColor
    $bodyLbl.Padding = New-Object System.Windows.Forms.Padding(14,6,14,0)

    $copyBtn = New-Object System.Windows.Forms.Button
    $copyBtn.Text = '复制译文'
    $copyBtn.FlatStyle = 'Flat'
    $copyBtn.BackColor = HexToColor $cfg.copyColor
    $copyBtn.ForeColor = Get-ContrastText $copyBtn.BackColor
    $copyBtn.FlatAppearance.BorderSize = 0
    $copyBtn.Cursor = 'Hand'

    $settingsBtn = New-Object System.Windows.Forms.Button
    $settingsBtn.Text = '设置'
    $settingsBtn.FlatStyle = 'Flat'
    $settingsBtn.BackColor = HexToColor $cfg.copyColor
    $settingsBtn.ForeColor = Get-ContrastText $settingsBtn.BackColor
    $settingsBtn.FlatAppearance.BorderSize = 0
    $settingsBtn.Cursor = 'Hand'
    $settingsBtn.Add_Click({
        try { Show-Settings } catch { Log ("打开设置失败: " + $_.Exception.Message) }
    })

    $closeBtn = New-Object System.Windows.Forms.Button
    $closeBtn.Text = '✕'
    $closeBtn.FlatStyle = 'Flat'
    $closeBtn.BackColor = HexToColor $cfg.closeColor
    $closeBtn.ForeColor = Get-ContrastText $closeBtn.BackColor
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
        if ($resp.nmtError -and -not $resp.translation) {
            $bodyLbl.Text = '（神经翻译暂不可用：' + [string]$resp.nmtError + '）'
            $script:copyPayload = ''
        }
        elseif ($resp.kind -eq 'sentence') {
            $bodyLbl.Text = [string]$resp.translation
            $script:copyPayload = [string]$resp.translation
        } else {
            if ($resp.translation) { $bodyLbl.Text = [string]$resp.translation; $script:copyPayload = [string]$resp.translation }
            elseif ($resp.bestSense.sense) { $bodyLbl.Text = '● ' + $resp.bestSense.sense; $script:copyPayload = [string]$resp.bestSense.sense }
            elseif ($resp.dictSenses) { $bodyLbl.Text = ($resp.dictSenses -join '  |  '); $script:copyPayload = ($resp.dictSenses -join ' | ') }
            if ($resp.contextTranslation) {
                if ($bodyLbl.Text) { $bodyLbl.Text += "`n语境: $($resp.contextTranslation)" }
                else { $bodyLbl.Text = [string]$resp.contextTranslation; $script:copyPayload = [string]$resp.contextTranslation }
            }
        }
    }

    $copyBtn.Add_Click({
        param($sender, $e)
        if ($script:copyPayload) {
            [System.Windows.Forms.Clipboard]::SetText($script:copyPayload)
            # 关键: 同步序列号, 避免"复制译文"被当成新的划词再翻一次
            try { $script:lastClipSeq = [MiaoNative.Clip]::GetClipboardSequenceNumber() } catch {}
            $script:lastText = $script:copyPayload
            $script:lastCopyTime = [DateTime]::Now
            $sender.Text = '已复制 ✓'
            Start-Sleep -Milliseconds 1200
            $sender.Text = '复制译文'
        }
    })
    $closeBtn.Add_Click({ param($sender, $e) $sender.FindForm().Close() })

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
    $bodyLbl.Top = $title.Height; $bodyLbl.Left = 12   # 文本框不支持内边距, 用左偏移留白
    # 正文字数高度: 最多显示 6 行, 超出则右侧出现滚动条
    $textW = [Math]::Max(40, $w - 28 - 10)
    $measured = [System.Windows.Forms.TextRenderer]::MeasureText(
        [string]$bodyLbl.Text, $bodyLbl.Font,
        (New-Object System.Drawing.Size($textW, 4000)),
        [System.Windows.Forms.TextFormatFlags]::WordBreak)
    $lineH = [int][Math]::Ceiling($bodyLbl.Font.GetHeight())
    $bodyLbl.Height = [int][Math]::Min($lineH * 6 + 14, [Math]::Max($lineH + 14, $measured.Height + 14))
    $popupH = [int]($bodyLbl.Bottom) + 40
    $f.ClientSize = New-Object System.Drawing.Size($w, $popupH)
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

    $script:popupForm = $f
    # 关闭后清空"已处理"记录, 以便同一段文本可以再次划词
    $f.Add_Paint({
        param($sender, $e)
        $bc = if ($script:borderColor) { $script:borderColor } else { '#E8DFCF' }
        $pen = New-Object System.Drawing.Pen((HexToColor $bc), 1)
        try { $e.Graphics.DrawRectangle($pen, 0, 0, $sender.ClientSize.Width - 1, $sender.ClientSize.Height - 1) }
        finally { $pen.Dispose() }
    })
    $f.Add_Shown({
        param($sender, $e)
        # 弹窗出现时文本框会默认全选(蓝色选中态) → 取消选中
        try { $bodyLbl.SelectionStart = 0; $bodyLbl.SelectionLength = 0 } catch {}
    })
    # 再次获得焦点时也不选中
    $bodyLbl.Add_GotFocus({
        param($sender, $e)
        try { $sender.SelectionLength = 0 } catch {}
    })
    $f.Show()
    $f.BringToFront()
    try { $bodyLbl.SelectionStart = 0; $bodyLbl.SelectionLength = 0 } catch {}
}

# ---------- 剪贴板监听（STA 必需；用 add_Tick 同 runspace 处理，避免跨会话作用域问题） ----------
$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 250
$timer.add_Tick({
    try {
        # 用剪贴板序列号判断"新的复制": 同样文字重新复制能再弹, 关闭后不会反复跳
        $seq = 0
        try { $seq = [MiaoNative.Clip]::GetClipboardSequenceNumber() } catch { $seq = 0 }
        if ($seq -ne 0) {
            if ($seq -eq $script:lastClipSeq) { return }
            $script:lastClipSeq = $seq
        } else {
            # 拿不到序列号: 用内容+2秒窗口兜底
            if (-not [System.Windows.Forms.Clipboard]::ContainsText()) { return }
            $t0 = [System.Windows.Forms.Clipboard]::GetText()
            if ($t0 -eq $script:lastSeen -and ([DateTime]::Now - $script:lastCopyTime).TotalSeconds -lt 2) { return }
            $script:lastSeen = $t0
        }
        if (-not [System.Windows.Forms.Clipboard]::ContainsText()) { return }
        $t = Normalize-Wrapped ([System.Windows.Forms.Clipboard]::GetText())
        if ([string]::IsNullOrWhiteSpace($t)) { return }
        $now = [DateTime]::Now
        Log ("剪贴板文本({0}字符)" -f $t.Length)
        if (Test-Garbled $t) {
            Log "判定为乱码, 提示不翻译"
            Show-Popup @{ error = '⚠ 复制内容疑似乱码（可能来自应用的复制保护），无法翻译' }
            $script:lastText = $t; $script:lastCopyTime = $now
            return
        }
        $resp = Request-Translation $t
        if ($resp) {
            if ($resp.disabled) {
                Log "服务端: 划词未开启(disabled), 不弹窗"
                $script:lastText = $t; $script:lastCopyTime = $now
                return
            }
            Log ("服务端响应: error={0} kind={1}" -f $resp.error, $resp.kind)
            Show-Popup $resp
        } else {
            Log "请求失败(翻译服务未运行?)"
            Show-Popup @{ error = '翻译服务未运行，请先启动: node server.js' }
        }
        $script:lastText = $t; $script:lastCopyTime = $now
    } catch {
        Log ("tick错误: {0}" -f $_)
    }
})
$script:lastText = ''
$script:lastCopyTime = [DateTime]::MinValue
$script:borderColor = '#E8DFCF'
# 启动时的基线：开启前就躺在剪贴板里的内容不算一次新划词
$script:lastSeen = $null
$script:lastClipSeq = 0
try {
    # 记录当前剪贴板序列号, 避免启动瞬间把已有内容当成"新复制"弹窗
    $script:lastClipSeq = [MiaoNative.Clip]::GetClipboardSequenceNumber()
} catch { $script:lastClipSeq = 0 }
try {
    if ([System.Windows.Forms.Clipboard]::ContainsText()) {
        $script:lastSeen = Normalize-Wrapped ([System.Windows.Forms.Clipboard]::GetText())
    }
} catch {}
$timer.Start()

# ---------- 设置窗口 ----------
function Show-Settings {
    $sf = New-Object System.Windows.Forms.Form
    $sf.Text = 'miaomiao翻译器 · 设置'
    $sf.FormBorderStyle = 'FixedDialog'
    $sf.StartPosition = 'CenterScreen'
    $sf.ClientSize = New-Object System.Drawing.Size(380, 452)
    $sf.BackColor = HexToColor '#F6F1E7'
    $sf.ForeColor = HexToColor '#1D1D1F'
    $sf.Padding = New-Object System.Windows.Forms.Padding(8)
    $sf.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 9)   # 统一字体, 消除点阵像素感

    # 控件统一放脚本作用域: PowerShell 事件处理器访问不到函数内的局部变量
    $script:stForm = $sf
    $script:stTrack = @{}
    $script:stValLbl = @{}

    function Add-Slider($parent, $y, $labelText, $min, $max, $value, $tag) {
        $lbl = New-Object System.Windows.Forms.Label
        $lbl.Text = $labelText; $lbl.SetBounds(16, $y, 96, 22)
        $lbl.ForeColor = HexToColor '#1D1D1F'
        $trk = New-Object System.Windows.Forms.TrackBar
        $trk.SetBounds(116, $y, 170, 30)
        $trk.Maximum = [int]$max; $trk.Minimum = [int]$min
        $trk.Value = [Math]::Min([Math]::Max([int]$value, [int]$min), [int]$max)
        $trk.Tag = [string]$tag
        $trk.SmallChange = 1          # 微调精度 1
        $trk.LargeChange = 10         # 拖动时的跳跃幅度
        $trk.BackColor = HexToColor '#F6F1E7'
        $val = New-Object System.Windows.Forms.Label
        $val.Text = "$($trk.Value)"; $val.SetBounds(294, $y, 52, 22)
        $val.ForeColor = HexToColor '#1D1D1F'
        $script:stTrack[[string]$tag] = $trk
        $script:stValLbl[[string]$tag] = $val
        $trk.Add_ValueChanged({
            param($sender, $e)
            $k = [string]$sender.Tag
            if ($script:stValLbl.ContainsKey($k)) { $script:stValLbl[$k].Text = "$($sender.Value)" }
        })
        $parent.Controls.Add($lbl); $parent.Controls.Add($trk); $parent.Controls.Add($val)
        return $trk
    }

    Add-Slider $sf 12 '弹窗宽度' 260 560 $cfg.width 'width' | Out-Null
    Add-Slider $sf 52 '划词字号' 10 24 $cfg.origFontSize 'origFontSize' | Out-Null
    Add-Slider $sf 92 '翻译字号' 10 24 $cfg.transFontSize 'transFontSize' | Out-Null
    Add-Slider $sf 172 '圆角弧度' 0 28 $cfg.radius 'radius' | Out-Null

    function Add-ColorBtn($parent, $y, $labelText, $colorKey) {
        $lbl = New-Object System.Windows.Forms.Label
        $lbl.Text = $labelText; $lbl.SetBounds(16, $y, 96, 24)
        $lbl.ForeColor = HexToColor '#1D1D1F'
        $btn = New-Object System.Windows.Forms.Button
        $btn.Tag = [string]$colorKey
        $btn.Text = '选择颜色'; $btn.SetBounds(116, $y, 100, 26)
        $btn.FlatStyle = 'Flat'
        $btn.BackColor = HexToColor $cfg[$colorKey]
        $btn.ForeColor = Get-ContrastText $btn.BackColor
        $btn.Add_Click({
            param($sender, $e)
            $k = [string]$sender.Tag
            $dlg = New-Object System.Windows.Forms.ColorDialog
            $dlg.Color = $sender.BackColor
            $dlg.FullOpen = $true
            if ($dlg.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
                $sender.BackColor = $dlg.Color
                $sender.ForeColor = Get-ContrastText $dlg.Color
                $cfg[$k] = ToHexColor $dlg.Color
                Save-Config $cfg
            }
        })
        $parent.Controls.Add($lbl); $parent.Controls.Add($btn)
    }

    Add-ColorBtn $sf 216 '背景颜色' 'bgColor'
    Add-ColorBtn $sf 252 '复制键颜色' 'copyColor'
    Add-ColorBtn $sf 288 '关闭键颜色' 'closeColor'
    Add-ColorBtn $sf 324 '原文字色' 'origColor'
    Add-ColorBtn $sf 360 '译文文字色' 'transColor'

    $okBtn = New-Object System.Windows.Forms.Button
    $okBtn.Text = '保存'
    $okBtn.SetBounds(296, 412, 68, 30)
    $okBtn.FlatStyle = 'Flat'
    $okBtn.BackColor = HexToColor $cfg.copyColor
    $okBtn.ForeColor = Get-ContrastText $okBtn.BackColor
    $okBtn.Add_Click({
        param($sender, $e)
        $cfg.width = $script:stTrack['width'].Value
        $cfg.origFontSize = $script:stTrack['origFontSize'].Value
        $cfg.transFontSize = $script:stTrack['transFontSize'].Value
        $cfg.radius = $script:stTrack['radius'].Value
        Save-Config $cfg
        $script:stForm.Close()
    })
    $sf.Controls.Add($okBtn)

    $cancelBtn = New-Object System.Windows.Forms.Button
    $cancelBtn.Text = '取消'
    $cancelBtn.SetBounds(222, 412, 64, 30)
    $cancelBtn.FlatStyle = 'Flat'
    $cancelBtn.BackColor = HexToColor $cfg.closeColor
    $cancelBtn.ForeColor = Get-ContrastText $cancelBtn.BackColor
    $cancelBtn.Add_Click({ param($sender, $e) $script:stForm.Close() })
    $sf.Controls.Add($cancelBtn)

    $sf.ShowDialog() | Out-Null
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
$itemSettings.Add_Click({
    try { Show-Settings } catch { Log ("托盘打开设置失败: " + $_.Exception.Message) }
})
$itemExit.Add_Click({ $timer.Stop(); $notify.Visible = $false; [System.Windows.Forms.Application]::Exit() })

Write-Host 'miaomiao翻译助手已启动 —— 选中文字后按 Ctrl+C（复制）即弹窗翻译'
Write-Host '右键托盘图标可设置/退出'

# 保持消息循环
[System.Windows.Forms.Application]::Run()
