# ---------------------------------------------------------------------------
#  Start WeChatDataAnalysis (WDA) for the Intel Bureau workbench.
#
#  Why this script exists instead of just double-clicking the shortcut:
#    1. Electron apps exit immediately with code 0 when ELECTRON_RUN_AS_NODE=1
#       is inherited from the parent shell. Some terminals and AI agent
#       sandboxes export it. We clear it here.
#    2. WDA 2.x binds its backend to a port it picks at install time and
#       remembers in desktop-settings.json (this machine: 10419), NOT the
#       documented 10392. We read the real port from that file and make sure
#       config\settings.yaml points at it.
#    3. We wait for /api/health and then report whether the workbench can
#       actually reach WDA, so "installed but not running" is unambiguous.
#
#  Usage:
#    powershell -ExecutionPolicy Bypass -File scripts\start-wda.ps1
#    powershell -ExecutionPolicy Bypass -File scripts\start-wda.ps1 -Restart
# ---------------------------------------------------------------------------
[CmdletBinding()]
param(
    [switch]$Restart,          # stop a running WDA first
    [switch]$NoConfigCheck     # do not touch config\settings.yaml
)

$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = [Text.Encoding]::UTF8 } catch { }

$Root = Split-Path -Parent $PSScriptRoot
$Exe = 'C:\Program Files\WeChatDataAnalysis\WeChatDataAnalysis.exe'
$WdaData = Join-Path $env:APPDATA 'wechat-data-analysis-desktop'
$SettingsFile = Join-Path $WdaData 'desktop-settings.json'
$BureauSettings = Join-Path $Root 'config\settings.yaml'

function Say([string]$m, [string]$c = 'Gray') { Write-Host $m -ForegroundColor $c }

# Electron apps must not inherit this; it turns them into a plain Node REPL.
Remove-Item Env:ELECTRON_RUN_AS_NODE -ErrorAction SilentlyContinue

function Test-Port([int]$Port) {
    $c = New-Object System.Net.Sockets.TcpClient
    try {
        $iar = $c.BeginConnect('127.0.0.1', $Port, $null, $null)
        if (-not $iar.AsyncWaitHandle.WaitOne(600)) { return $false }
        $c.EndConnect($iar)
        return $true
    } catch { return $false } finally { $c.Close() }
}

function Get-WdaPort {
    # The backend port WDA actually uses is persisted here at install time.
    if (Test-Path -LiteralPath $SettingsFile) {
        try {
            $j = Get-Content -LiteralPath $SettingsFile -Raw -Encoding UTF8 | ConvertFrom-Json
            if ($j.backendPort) { return [int]$j.backendPort }
        } catch { }
    }
    return 10392            # documented default, used only if the file is absent
}

if (-not (Test-Path -LiteralPath $Exe)) {
    Say ''
    Say '没有找到 WeChatDataAnalysis。' 'Red'
    Say '先运行：powershell -ExecutionPolicy Bypass -File scripts\tools\get-wechat-data-analysis.ps1'
    Say '再双击 third_party\tools\wda\ 里的 Setup.exe 安装，然后重新运行本脚本。'
    exit 1
}

$port = Get-WdaPort
$url = "http://127.0.0.1:$port"

if ($Restart) {
    Say '停止正在运行的 WDA...' 'Yellow'
    Get-Process -Name 'WeChatDataAnalysis', 'wechat-backend' -ErrorAction SilentlyContinue |
        Stop-Process -Force -ErrorAction SilentlyContinue
    for ($i = 0; $i -lt 20; $i++) {
        if (-not (Test-Port $port)) { break }
        Start-Sleep -Milliseconds 500
    }
}

# ---------------------------------------------------------------- start
if (Test-Port $port) {
    Say "WDA 已经在运行（端口 $port）。" 'Green'
} else {
    Say "启动 WeChatDataAnalysis（端口 $port）..." 'Cyan'
    Start-Process -FilePath $Exe -WorkingDirectory (Split-Path -Parent $Exe)
    $up = $false
    for ($i = 0; $i -lt 90; $i++) {                 # 后端冷启动约 25 秒，最多等 90 秒
        if (Test-Port $port) { $up = $true; break }
        Start-Sleep -Seconds 1
    }
    if (-not $up) {
        Say ''
        Say "WDA 没有在 90 秒内监听端口 $port。" 'Red'
        $main = Join-Path $WdaData 'desktop-main.log'
        if (Test-Path -LiteralPath $main) {
            Say '最近的日志：' 'Yellow'
            Get-Content -LiteralPath $main -Tail 10 -Encoding UTF8 | ForEach-Object { Say "  $_" }
        }
        Say '常见原因：微信没有登录；WDA 被安全软件拦截；端口被别的程序占用。' 'Yellow'
        exit 1
    }
    Say '后端已启动。' 'Green'
}

# ---------------------------------------------------------------- health
$health = $null
for ($i = 0; $i -lt 30; $i++) {
    try {
        $health = Invoke-RestMethod -Uri "$url/api/health" -TimeoutSec 5
        if ($health.status -eq 'healthy') { break }
    } catch { }
    Start-Sleep -Seconds 1
}
if ($health -and $health.status -eq 'healthy') {
    Say "WDA 健康检查通过：$url/api/health" 'Green'
} else {
    Say "端口 $port 已监听，但 /api/health 还没就绪，稍等几秒再试。" 'Yellow'
}

# ------------------------------------------------- keep bureau config in sync
#
# Only the `wda:` block may be touched. A naive regex over the whole file (or
# even over "everything indented after wda:") also rewrites weflow (5031) and
# onebot (3010), which silently breaks those adapters. So: find the `wda:` line,
# then walk forward while lines are blank or indented deeper than `wda:` itself,
# and edit base_url only inside that exact range.
if (-not $NoConfigCheck -and (Test-Path -LiteralPath $BureauSettings)) {
    $lines = [System.Collections.Generic.List[string]](Get-Content -LiteralPath $BureauSettings -Encoding UTF8)
    $wdaIdx = -1
    $wdaIndent = 0
    for ($i = 0; $i -lt $lines.Count; $i++) {
        $mm = [regex]::Match($lines[$i], '^(\s*)wda:\s*$')
        if ($mm.Success) { $wdaIdx = $i; $wdaIndent = $mm.Groups[1].Length; break }
    }

    if ($wdaIdx -ge 0) {
        # End of the block = first following line that is non-blank and not deeper.
        $end = $wdaIdx
        for ($i = $wdaIdx + 1; $i -lt $lines.Count; $i++) {
            if ($lines[$i].Trim() -eq '') { $end = $i; continue }
            $ind = [regex]::Match($lines[$i], '^(\s*)').Groups[1].Length
            if ($ind -le $wdaIndent) { break }
            $end = $i
        }

        # Locate base_url inside [$wdaIdx+1 .. $end].
        $urlIdx = -1
        for ($i = $wdaIdx + 1; $i -le $end; $i++) {
            if ($lines[$i] -match '^(\s*)base_url:\s*http://127\.0\.0\.1:(\d+)\s*$') {
                $urlIdx = $i
                $curPort = [int]$Matches[2]
                $urlIndent = $Matches[1]
                break
            }
        }

        if ($urlIdx -lt 0) {
            Say '在 config\settings.yaml 的 wda: 段里没找到 base_url，跳过自动同步。' 'Yellow'
            Say "请手动把 sources.wechat.wda.base_url 设为 $url" 'Yellow'
        } elseif ($curPort -ne $port) {
            $bakDir = Join-Path $Root 'data\backups'
            New-Item -ItemType Directory -Force -Path $bakDir | Out-Null
            $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
            $bak = Join-Path $bakDir "settings.yaml.$stamp.bak"
            Copy-Item -LiteralPath $BureauSettings -Destination $bak -Force
            $lines[$urlIdx] = "$urlIndent" + "base_url: $url"
            [System.IO.File]::WriteAllLines($BureauSettings, $lines, [System.Text.UTF8Encoding]::new($false))
            Say "已把 config\settings.yaml 里 wda.base_url 改成 $url（备份：$bak）。" 'Yellow'
            Say '需要重启工作台才会生效。' 'Yellow'
        } else {
            Say "工作台配置的 WDA 地址已经是 $url，无需改动。" 'Green'
        }
    }
}

Say ''
Say '完成。' 'Cyan'
Say "  WDA 地址：$url"
Say '  安全提醒：本地 API 无鉴权且 CORS 为 *，运行期间不要打开不可信网页，不用时关掉 WDA。'
Say '  微信需要保持登录状态，WDA 里要开启「实时模式」才能读到最新消息。'
