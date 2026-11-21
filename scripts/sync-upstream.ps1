# ---------------------------------------------------------------------------
#  Keep this fork in sync with the upstream repository.
#
#  This is a *personal fork*: `main` contains upstream history plus local
#  commits (see `git log upstream/main..main`). So the right move is to MERGE
#  upstream/main into main, never rebase -- rebasing would rewrite commits that
#  are already pushed to the fork and to any PR opened from it.
#
#  Usage:
#    powershell -ExecutionPolicy Bypass -File scripts\sync-upstream.ps1
#        只看差异，不动任何东西（默认就是只看）
#    powershell -ExecutionPolicy Bypass -File scripts\sync-upstream.ps1 -Apply
#        真的有新提交时才合并，冲突会自动中止并恢复原状
#    powershell -ExecutionPolicy Bypass -File scripts\sync-upstream.ps1 -Apply -Push
#        合并后顺便推到 fork 的 origin/main
# ---------------------------------------------------------------------------
[CmdletBinding()]
param(
    [switch]$Apply,        # 默认只预览，不动工作区
    [switch]$Push,         # 合并成功后推送到 origin
    [string]$Remote = 'upstream',
    [string]$Branch = 'main'
)

$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = [Text.Encoding]::UTF8 } catch { }

$Root = Split-Path -Parent $PSScriptRoot
Set-Location $Root

function Say([string]$m, [string]$c = 'Gray') { Write-Host $m -ForegroundColor $c }
function Fail([string]$m) { Say ''; Say $m 'Red'; Say ''; exit 1 }

# ---------------------------------------------------------------- 前置检查
$remotes = @(git remote)
if ($remotes -notcontains $Remote) {
    Fail "没有名为 $Remote 的远程。当前远程：$($remotes -join ', ')`n" +
         "先加一个：git remote add upstream https://github.com/Merziller/intel-bureau.git"
}

# 工作区必须是干净的，否则合并失败会很难收拾
$dirty = @(git status --porcelain)
if ($dirty.Count -gt 0) {
    Say '工作区有未提交的改动：' 'Yellow'
    $dirty | ForEach-Object { Say "  $_" }
    Fail "先提交或 stash 再同步。`n  git stash push -u -m sync-upstream`n  （同步完再 git stash pop）"
}

$current = (git rev-parse --abbrev-ref HEAD).Trim()
if ($current -ne $Branch) {
    Say "当前在分支 $current，切到 $Branch ..." 'Yellow'
    git checkout $Branch | Out-Null
    if ($LASTEXITCODE -ne 0) { Fail "切不到 $Branch" }
}

# ---------------------------------------------------------------- 拉取
Say "拉取 $Remote ..." 'Cyan'
git fetch $Remote --prune --tags | Out-Null
if ($LASTEXITCODE -ne 0) { Fail "git fetch $Remote 失败（网络或代理问题？）" }

$upstreamRef = "$Remote/$Branch"
if (-not (git rev-parse --verify --quiet $upstreamRef)) {
    Fail "$upstreamRef 不存在。分支名对不对？"
}

$behind = @(git log --oneline "HEAD..$upstreamRef")
$ahead = @(git log --oneline "$upstreamRef..HEAD")

Say ''
Say "本地 $Branch : $(git rev-parse --short HEAD)  $(git log -1 --format=%s HEAD)"
Say "上游 $upstreamRef : $(git rev-parse --short $upstreamRef)  $(git log -1 --format=%s $upstreamRef)"
Say ''

if ($behind.Count -eq 0) {
    Say '上游没有新提交，已经是最新。' 'Green'
    if ($ahead.Count -gt 0) {
        Say ''
        Say "你的本地提交（上游没有，共 $($ahead.Count) 个）：" 'Cyan'
        $ahead | ForEach-Object { Say "  $_" }
    }
    exit 0
}

Say "上游有 $($behind.Count) 个新提交：" 'Yellow'
$behind | ForEach-Object { Say "  $_" }
if ($ahead.Count -gt 0) {
    Say ''
    Say "你的本地提交（合并时会保留，共 $($ahead.Count) 个）：" 'Cyan'
    $ahead | ForEach-Object { Say "  $_" }
}

Say ''
Say '上游改到的文件：' 'Cyan'
$stat = @(git diff --stat "HEAD...$upstreamRef")
$stat | Where-Object { $_ -match '\|' } | ForEach-Object { Say "  $_".TrimEnd() }

# 你的改动和上游冲突风险：两边都动过的文件
$mineFiles = @(git diff --name-only "$(git merge-base HEAD $upstreamRef)" HEAD)
$theirFiles = @(git diff --name-only "$(git merge-base HEAD $upstreamRef)" $upstreamRef)
$overlap = @($mineFiles | Where-Object { $theirFiles -contains $_ })
if ($overlap.Count -gt 0) {
    Say ''
    Say '⚠ 这些文件你也改过，合并时可能冲突：' 'Yellow'
    $overlap | ForEach-Object { Say "  $_" 'Yellow' }
} else {
    Say ''
    Say '两边没有改到同一个文件，合并应该很干净。' 'Green'
}

if (-not $Apply) {
    Say ''
    Say '预览结束，没有做任何改动。' 'Cyan'
    Say "真正合并请加 -Apply：powershell -ExecutionPolicy Bypass -File scripts\sync-upstream.ps1 -Apply"
    exit 0
}

# ---------------------------------------------------------------- 合并
Say ''
Say "合并 $upstreamRef 到 $Branch ..." 'Cyan'
$before = (git rev-parse HEAD).Trim()
git merge --no-edit $upstreamRef 2>&1 | ForEach-Object { Say "  $_" }

if ($LASTEXITCODE -ne 0) {
    Say ''
    Say '合并出现冲突。正在恢复到合并前的状态 ...' 'Yellow'
    git merge --abort 2>&1 | Out-Null
    $now = (git rev-parse HEAD).Trim()
    if ($now -eq $before) {
        Say "已恢复到 $($before.Substring(0,7))，工作区是干净的。" 'Green'
    } else {
        Say "警告：没能完全恢复，请手动检查 git status。" 'Red'
    }
    Say ''
    Say '处理办法：' 'Cyan'
    Say '  1. 看上面列出的冲突文件，手动合并两边的内容；'
    Say '  2. 或者只挑上游的提交：git cherry-pick <上游提交号>'
    Say "  3. 再跑一次本脚本的 -Apply。"
    exit 1
}

$after = (git rev-parse HEAD).Trim()
Say ''
Say "已合并：$($before.Substring(0,7)) -> $($after.Substring(0,7))" 'Green'

# ---------------------------------------------------------------- 自检
# 合并后至少确认代码还能导入、测试还能过，避免上游改动把本地用法弄坏
$VenvPy = Join-Path $Root '.venv\Scripts\python.exe'
if (Test-Path $VenvPy) {
    Say ''
    Say '自检：编译 + 导入 ...' 'Cyan'
    & $VenvPy -X utf8 -c "import compileall,sys; sys.exit(0 if compileall.compile_dir('bureau', quiet=2) else 1)"
    if ($LASTEXITCODE -ne 0) { Say '编译失败，先别推送。' 'Red'; exit 1 }
    & $VenvPy -X utf8 -c "import bureau; print('bureau 导入正常')"
    if ($LASTEXITCODE -ne 0) { Say '导入失败，先别推送。' 'Red'; exit 1 }
    Say '自检通过。' 'Green'
    Say '建议再跑一次测试：.venv\Scripts\python.exe -X utf8 -m pytest -q' 'Gray'
}

# ---------------------------------------------------------------- 推送
if ($Push) {
    Say ''
    Say '推送到 origin ...' 'Cyan'
    git push origin $Branch 2>&1 | ForEach-Object { Say "  $_" }
    if ($LASTEXITCODE -ne 0) { Fail '推送失败。' }
    Say '已推送。' 'Green'
} else {
    Say ''
    Say "合并完成但还没推送。确认没问题后：git push origin $Branch" 'Cyan'
}
