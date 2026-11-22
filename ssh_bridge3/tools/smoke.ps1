# dist-smoke.ps1 — 解压后自检（冒烟，不改代码、不依赖仓库）
# 用法： pwsh -NoProfile -File tools\smoke.ps1 [-Exe .\ssh_bridge3.exe] [-Port 18086]
#
# 做四件事：起进程 → /ping + /ui-tree 确认控件在册 → 驱动输入/搜索/分屏 → 退出关端口
# 退出码： 0 = 冒烟通过；1 = 失败（会打印失败项）

param(
    [string]$Exe  = '',
    [int]$Port    = 18086
)

$here = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
if (-not $Exe) { $Exe = Join-Path $here '..\ssh_bridge3.exe' }
$ErrorActionPreference = 'Stop'
$base = "http://127.0.0.1:$Port"
$work = Join-Path $here '..'
$exe  = (Resolve-Path -LiteralPath $Exe).Path
$fails = @()

function Ok([string]$name, [bool]$cond, [string]$detail = '') {
    if ($cond) { Write-Host ("  PASS  {0}  {1}" -f $name, $detail) }
    else { $script:fails += $name; Write-Host ("  FAIL  {0}  {1}" -f $name, $detail) -ForegroundColor Red }
}

function Get-J([string]$path) {
    $r = Invoke-WebRequest -UseBasicParsing -SkipHttpErrorCheck -Uri "$base$path" -TimeoutSec 10
    if ($r.StatusCode -ne 200) { throw "HTTP $($r.StatusCode) $path" }
    return ($r.Content | ConvertFrom-Json)
}

function Act([string]$id, [string]$action, $text = $null, $value = $null) {
    $b = @{ id = $id; action = $action }
    if ($null -ne $text) { $b['text'] = $text }
    if ($null -ne $value) { $b['value'] = $value }
    $r = Invoke-WebRequest -UseBasicParsing -SkipHttpErrorCheck -Method Post -Uri "$base/action" `
        -ContentType 'application/json; charset=utf-8' -Body ($b | ConvertTo-Json -Compress) -TimeoutSec 15
    return ($r.Content | ConvertFrom-Json)
}

Get-Process -Name 'ssh_bridge3' -ErrorAction SilentlyContinue | Stop-Process -Force
Start-Sleep -Milliseconds 400
$p = Start-Process -FilePath $exe -WorkingDirectory $work -PassThru
$up = $false
for ($i = 0; $i -lt 80; $i++) {
    Start-Sleep -Milliseconds 150
    try {
        $r = Invoke-WebRequest -UseBasicParsing -SkipHttpErrorCheck -Uri "$base/ping" -TimeoutSec 2
        if ($r.StatusCode -eq 200) { $up = $true; break }
    } catch { }
    if ($p.HasExited) { break }
}

try {
    Ok 'bridge-up' $up "pid=$($p.Id)"
    if ($up) {
        $tree = Get-J '/ui-tree'
        Ok 'ui-tree-count' (@($tree.controls).Count -ge 34) "count=$($tree.count)"
        Ok 'no-auto-id' (@($tree.controls | Where-Object { $_.id -like 'auto/*' }).Count -eq 0) ''

        $r1 = Act 'edit.search' 'set_text' 'smoke-hit'
        Start-Sleep -Milliseconds 400
        $t1 = Act 'edit.search' 'get_text'
        Ok 'edit.search' ($r1.ok -eq $true -and $t1.result.text -eq 'smoke-hit') "text='$($t1.result.text)'"
        Act 'edit.search' 'clear' | Out-Null

        # 桥接 text 字段上限 512 字节，分 4 批各 30 行灌入，保证有回看行
        foreach ($batch in 0..3) {
            $chunk = (($batch * 30 + 1)..($batch * 30 + 30) | ForEach-Object { "smoke-line-$_" }) -join "`r`n"
            Act 'term.send' 'set_text' ($chunk + "`r`n") | Out-Null
            Start-Sleep -Milliseconds 500
        }
        Start-Sleep -Milliseconds 800
        $s = Act 'term.search' 'set_text' 'smoke-line-31'
        $st = (Get-J '/state').state
        Ok 'term.search' ($s.ok -eq $true -and $st.terminal.panes[0].search_hit -eq $true) `
            "found=$($s.result.found)"

        Act 'term.scroll' 'set_value' $null 4 | Out-Null
        Start-Sleep -Milliseconds 400
        # 回看不足 4 行时会被夹到上限，这是正确行为；断言“等于 min(4, max)”
        $sl = (Get-J '/control?id=term.scroll').control
        $off = (Get-J '/state').state.terminal.panes[0].offset
        $exp = [Math]::Min(4, [int]$sl.max)
        Ok 'term.scroll' ($off -eq $exp) "offset=$off max=$($sl.max) expect=$exp"

        Act 'term.split2' 'click' | Out-Null
        Start-Sleep -Milliseconds 700
        Ok 'term.split2' ((Get-J '/state').state.terminal.split -eq 2) "split=$((Get-J '/state').state.terminal.split)"
        Act 'term.split1' 'click' | Out-Null
        Act 'menu.help.about' 'click' | Out-Null
        Start-Sleep -Milliseconds 500
        Ok 'about-window' ((Get-J '/state').state.about_open -eq $true) ''
        Act 'btn.about.ok' 'click' | Out-Null
        Start-Sleep -Milliseconds 300
        Ok 'about-close' ((Get-J '/state').state.about_open -eq $false) ''
    }
}
finally {
    Get-Process -Name 'ssh_bridge3' -ErrorAction SilentlyContinue | Stop-Process -Force
    Start-Sleep -Milliseconds 500
}

if ($fails.Count -eq 0) { Write-Host 'RESULT: SMOKE PASS' -ForegroundColor Green; exit 0 }
Write-Host ("RESULT: {0} FAIL" -f $fails.Count) -ForegroundColor Red
exit 1
