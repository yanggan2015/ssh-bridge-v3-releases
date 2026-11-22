# update.ps1 — ssh-bridge v3 独立更新器（白名单替换，不碰配置/工作目录/日志）
# 用法：
#   powershell -NoProfile -File tools\update.ps1 [-Manifest <UPDATE.json 的 http(s) 地址或本地路径>] [-CheckOnly] [-NoRestart]
#
# 默认清单：https://raw.githubusercontent.com/yanggan2015/ssh-bridge-v3-releases/windows_x86_64/UPDATE.json
#
# 安全边界：
#   1. 只更新 ssh_bridge3.exe、README.md、VERSION.txt、tools\ 下的文件。
#   2. 永远不改 ssh_bridge_config.json、work\、logs\、keys\ 或任何用户数据。
#   3. 先校验 zip 的 SHA-256 和 exe 的 SHA-256，再停止程序并替换。
#   4. 替换失败自动从备份回滚；成功后才删除临时目录。
#
# 退出码：0 = 已是最新或更新成功；2 = 有更新（仅 -CheckOnly）；1 = 失败。

param(
    [string]$Manifest = 'https://raw.githubusercontent.com/yanggan2015/ssh-bridge-v3-releases/windows_x86_64/UPDATE.json',
    [string]$ManifestFallback = '',
    [string]$InstallDir = '',
    [switch]$CheckOnly,
    [switch]$NoRestart
)

$DefaultManifest = 'https://raw.githubusercontent.com/yanggan2015/ssh-bridge-v3-releases/windows_x86_64/UPDATE.json'
$LatestReleaseManifest = 'https://github.com/yanggan2015/ssh-bridge-v3-releases/releases/latest/download/UPDATE.json'

$here = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
if (-not $InstallDir) { $InstallDir = Join-Path $here '..' }

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
Add-Type -AssemblyName System.IO.Compression.FileSystem

function Fail([string]$msg) {
    Write-Host "UPDATE: FAIL $msg" -ForegroundColor Red
    exit 1
}

function TryFetchText([string]$uri) {
    for ($i = 1; $i -le 3; $i++) {
        try {
            $resp = Invoke-WebRequest -UseBasicParsing -Uri $uri -TimeoutSec 60
            $body = $resp.Content
            if ($body -is [byte[]]) { return [Text.Encoding]::UTF8.GetString($body) }
            return [string]$body
        } catch {
            if ($i -lt 3) {
                Write-Host "UPDATE: retry manifest ($i/3): $($_.Exception.Message)"
                Start-Sleep -Seconds 2
            }
        }
    }
    Write-Host "UPDATE: manifest source failed: $uri"
    return $null
}

function FetchFile([string]$uri, [string]$outFile) {
    # 重试与备用直链由调用侧的 zip 候选循环统一处理，这里只做一次尝试。
    Invoke-WebRequest -UseBasicParsing -Uri $uri -OutFile $outFile -TimeoutSec 180
}

function Get-VersionFile([string]$path) {
    if (-not (Test-Path -LiteralPath $path)) { return '0.0.0' }
    foreach ($line in Get-Content -LiteralPath $path) {
        if ($line -match '^\s*version\s*=\s*(.+?)\s*$') { return $Matches[1] }
    }
    return '0.0.0'
}

function Compare-Token([string]$x, [string]$y) {
    if ($x -eq $y) { return 0 }
    $mx = [regex]::Match($x, '^([A-Za-z]*)(\d+)$')
    $my = [regex]::Match($y, '^([A-Za-z]*)(\d+)$')
    if ($mx.Success -and $my.Success) {
        $px = $mx.Groups[1].Value
        $py = $my.Groups[1].Value
        $c = [string]::CompareOrdinal($px, $py)
        if ($c -ne 0) { return [Math]::Sign($c) }
        $nx = [int64]$mx.Groups[2].Value
        $ny = [int64]$my.Groups[2].Value
        if ($nx -gt $ny) { return 1 }
        if ($nx -lt $ny) { return -1 }
        return 0
    }
    return [Math]::Sign([string]::CompareOrdinal($x, $y))
}

function Compare-Ver([string]$a, [string]$b) {
    $a = $a.Trim().TrimStart('v', 'V')
    $b = $b.Trim().TrimStart('v', 'V')
    $aParts = $a -split '-'
    $bParts = $b -split '-'
    $aBase = $aParts[0]
    $bBase = $bParts[0]
    try { $av = [version]$aBase } catch { $av = [version]'0.0.0' }
    try { $bv = [version]$bBase } catch { $bv = [version]'0.0.0' }
    if ($av -gt $bv) { return 1 }
    if ($av -lt $bv) { return -1 }
    $n = [Math]::Max($aParts.Count, $bParts.Count)
    for ($i = 1; $i -lt $n; $i++) {
        $as = if ($i -lt $aParts.Count) { [string]$aParts[$i] } else { '' }
        $bs = if ($i -lt $bParts.Count) { [string]$bParts[$i] } else { '' }
        if ($as -eq '') { return -1 }
        if ($bs -eq '') { return 1 }
        $c = Compare-Token $as $bs
        if ($c -ne 0) { return $c }
    }
    return 0
}

function Get-Sha256([string]$path) {
    $sha = [System.Security.Cryptography.SHA256]::Create()
    $stream = [System.IO.File]::OpenRead($path)
    try {
        $hash = $sha.ComputeHash($stream)
        return ([System.BitConverter]::ToString($hash)).Replace('-', '').ToUpperInvariant()
    } finally {
        $stream.Dispose()
        $sha.Dispose()
    }
}

$install = (Resolve-Path -LiteralPath $InstallDir).Path
$exePath = Join-Path $install 'ssh_bridge3.exe'
if (-not (Test-Path -LiteralPath $exePath)) { Fail "安装目录缺少 ssh_bridge3.exe：$install" }
$versionPath = Join-Path $install 'VERSION.txt'
$localVersion = Get-VersionFile $versionPath
Write-Host "UPDATE: install=$install current=$localVersion"
$tracePath = Join-Path $install 'work\logs\update-trace.log'
function Trace([string]$m) {
    try { Add-Content -LiteralPath $tracePath -Value ("{0:o} {1}" -f (Get-Date), $m) -ErrorAction SilentlyContinue } catch { }
}
Trace "START pid=$PID host=$($PSVersionTable.PSVersion)"
trap { Trace "TRAP $_"; exit 1 }

$isHttp = $Manifest -match '^https?://'
$manifestDir = ''
$manifestUri = $Manifest
$m = $null
$text = $null
if ($isHttp) {
    $manifestCandidates = [System.Collections.Generic.List[string]]::new()
    foreach ($u in @($Manifest, $ManifestFallback)) {
        if ($u -and $u -match '^https?://' -and -not $manifestCandidates.Contains($u)) {
            $manifestCandidates.Add($u) | Out-Null
        }
    }
    # 默认 raw 清单失败时，退到最新 Release 上的稳定 UPDATE.json 资产。
    if ($Manifest -eq $DefaultManifest -and -not $manifestCandidates.Contains($LatestReleaseManifest)) {
        $manifestCandidates.Add($LatestReleaseManifest) | Out-Null
    }
    Trace "MANIFEST_CANDIDATES=$($manifestCandidates -join ',')"
    foreach ($candidate in $manifestCandidates) {
        $candidateText = TryFetchText $candidate
        if (-not $candidateText) { continue }
        $candidateObj = $null
        try { $candidateObj = $candidateText | ConvertFrom-Json } catch {
            Write-Host "UPDATE: manifest JSON invalid: $candidate"
            continue
        }
        if (-not $candidateObj.version -or (-not $candidateObj.zip -and -not $candidateObj.url) -or -not $candidateObj.sha256) {
            Write-Host "UPDATE: manifest fields missing: $candidate"
            continue
        }
        $text = $candidateText
        $m = $candidateObj
        $manifestUri = $candidate
        Trace "MANIFEST_OK $candidate version=$($m.version)"
        Write-Host "UPDATE: manifest=$candidate"
        break
    }
    if (-not $m) { Fail "下载清单失败：已尝试 $($manifestCandidates.Count) 个来源" }
} else {
    if (-not (Test-Path -LiteralPath $Manifest)) { Fail "清单不存在：$Manifest" }
    $manifestPath = (Resolve-Path -LiteralPath $Manifest).Path
    $manifestDir = Split-Path -Parent $manifestPath
    $text = Get-Content -LiteralPath $manifestPath -Raw
}

if (-not $m) {
    try { $m = $text | ConvertFrom-Json } catch { Fail '清单不是合法 JSON' }
}
if (-not $m.version -or (-not $m.zip -and -not $m.url) -or -not $m.sha256) {
    Fail '清单缺少 version / (zip 或 url) / sha256'
}

$cmp = Compare-Ver $m.version $localVersion
Write-Host "UPDATE: remote=$($m.version)"
Trace "REMOTE=$($m.version) CMP=$cmp"
if ($cmp -le 0) {
    Write-Host 'UPDATE: OK already-up-to-date' -ForegroundColor Green
    exit 0
}
if ($CheckOnly) {
    Write-Host 'UPDATE: OK update-available' -ForegroundColor Yellow
    exit 2
}

$tmp = Join-Path ([System.IO.Path]::GetTempPath()) ('sb3-update-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $tmp | Out-Null
try {
    $zipRef = if ($m.url) { [string]$m.url } else { [string]$m.zip }
    $zipIsUrl = $zipRef -match '^https?://'
    $localZip = ''
    $zipCandidates = [System.Collections.Generic.List[string]]::new()
    # GitHub Release 资产是固定直链，优先于 raw 分支；raw 在部分网络会 reset/截断。
    if ($m.github_url) {
        $gh = [string]$m.github_url
        if ($gh -match '^https?://' -and -not $zipCandidates.Contains($gh)) { $zipCandidates.Add($gh) | Out-Null }
    }
    if ($zipIsUrl) {
        if (-not $zipCandidates.Contains($zipRef)) { $zipCandidates.Add($zipRef) | Out-Null }
    } elseif ($isHttp) {
        $rel = [Uri]::new([Uri]$manifestUri, $zipRef)
        if ($rel.Scheme -notin @('http', 'https')) { Fail "不支持的下载协议：$($rel.Scheme)" }
        if (-not $zipCandidates.Contains($rel.AbsoluteUri)) { $zipCandidates.Add($rel.AbsoluteUri) | Out-Null }
    } else {
        $localZip = if ([System.IO.Path]::IsPathRooted($zipRef)) { $zipRef } else { Join-Path $manifestDir $zipRef }
        if (-not (Test-Path -LiteralPath $localZip)) { Fail "更新包不存在：$localZip" }
    }
    $zipPath = Join-Path $tmp 'package.zip'
    $wantZip = ([string]$m.sha256 -split '\s+')[0].ToUpperInvariant()
    $wantSize = if ($m.size_bytes) { [int64]$m.size_bytes } else { 0 }
    $zipOk = $false
    if ($localZip) {
        Copy-Item -LiteralPath $localZip -Destination $zipPath -Force
        $gotSize = (Get-Item -LiteralPath $zipPath).Length
        $gotZip = Get-Sha256 $zipPath
        if (($wantSize -eq 0 -or $gotSize -eq $wantSize) -and $wantZip -eq $gotZip) {
            $zipOk = $true
            Trace "LOCAL_ZIP_OK $localZip"
        }
    }

    Trace "ZIP_SHA_BEGIN want=$wantZip size=$wantSize candidates=$($zipCandidates.Count)"
    foreach ($candidate in $zipCandidates) {
        if ($zipOk) { break }
        for ($attempt = 1; $attempt -le 3; $attempt++) {
            if ($attempt -gt 1) { Remove-Item -Force $zipPath -ErrorAction SilentlyContinue }
            Trace "BEFORE_FETCH $candidate try=$attempt"
            try {
                FetchFile $candidate $zipPath
            } catch {
                Write-Host "UPDATE: fetch retry ($attempt/3): $($_.Exception.Message)"
                Trace "FETCH_FAIL $candidate try=$attempt $($_.Exception.Message)"
                if ($attempt -lt 3) { Start-Sleep -Seconds 2 }
                continue
            }
            Trace "AFTER_FETCH size=$((Get-Item -LiteralPath $zipPath).Length) candidate=$candidate"
            $gotSize = (Get-Item -LiteralPath $zipPath).Length
            $gotZip = Get-Sha256 $zipPath
            if (($wantSize -eq 0 -or $gotSize -eq $wantSize) -and $wantZip -eq $gotZip) {
                $zipOk = $true
                break
            }
            Write-Host "UPDATE: zip integrity retry ($attempt/3) size=$gotSize expect=$wantSize sha=$gotZip"
            Trace "ZIP_BAD $candidate try=$attempt size=$gotSize sha=$gotZip"
            Start-Sleep -Seconds 2
        }
    }
    if (-not $zipOk) { Fail "zip SHA-256/大小校验失败：期望 $wantZip" }
    Write-Host 'UPDATE: OK zip-sha256'
    Trace 'ZIP_SHA_OK'

    $stage = Join-Path $tmp 'stage'
    New-Item -ItemType Directory -Force -Path $stage | Out-Null
    $archive = [System.IO.Compression.ZipFile]::OpenRead($zipPath)
    try {
        foreach ($entry in $archive.Entries) {
            if ([string]::IsNullOrEmpty($entry.Name)) { continue }
            $name = ($entry.FullName -replace '\\', '/')
            $parts = $name -split '/'
            if ($name.StartsWith('/') -or $name -match '^[A-Za-z]:' -or ($parts -contains '..') -or ($parts -contains '')) {
                Fail "更新包非法路径：$name"
            }
            $allowed = $false
            if ($name -eq 'ssh_bridge3.exe') { $allowed = $true }
            elseif ($name -eq 'README.md') { $allowed = $true }
            elseif ($name -eq 'VERSION.txt') { $allowed = $true }
            elseif ($name -match '^tools/[^/]+$') { $allowed = $true }
            if (-not $allowed) { continue }
            $dest = Join-Path $stage $name
            New-Item -ItemType Directory -Force -Path (Split-Path -Parent $dest) | Out-Null
            [System.IO.Compression.ZipFileExtensions]::ExtractToFile($entry, $dest, $true)
        }
    } finally {
        $archive.Dispose()
    }

    $stagedExe = Join-Path $stage 'ssh_bridge3.exe'
    Trace "EXTRACTED files=$((Get-ChildItem -LiteralPath $stage -Recurse -File).Count)"
    if (-not (Test-Path -LiteralPath $stagedExe)) { Fail '更新包缺少 ssh_bridge3.exe' }
    if (-not (Test-Path -LiteralPath (Join-Path $stage 'VERSION.txt'))) { Fail '更新包缺少 VERSION.txt' }
    if ($m.exe_sha256) {
        $gotExe = Get-Sha256 $stagedExe
        $wantExe = ([string]$m.exe_sha256 -split '\s+')[0].ToUpperInvariant()
        if ($wantExe -ne $gotExe) { Fail "exe SHA-256 不匹配：期望 $wantExe 实际 $gotExe" }
        Write-Host 'UPDATE: OK exe-sha256'
    }

    # 只停止安装目录里的实例，避免误杀同一台机器上别的测试目录进程
    $wasRunning = $false
    foreach ($p in @(Get-Process ssh_bridge3 -ErrorAction SilentlyContinue)) {
        try {
            $procPath = $p.Path
            if ($procPath -and ((Split-Path -Parent $procPath) -eq $install)) {
                $wasRunning = $true
                Stop-Process -Id $p.Id -Force
            }
        } catch { }
    }
    if ($wasRunning) { Start-Sleep -Milliseconds 900 }
    Trace "STOPPED wasRunning=$wasRunning"

    $backup = Join-Path $tmp 'backup'
    New-Item -ItemType Directory -Force -Path $backup | Out-Null
    $updated = [System.Collections.Generic.List[string]]::new()
    try {
        $files = @(Get-ChildItem -LiteralPath $stage -Recurse -File)
        foreach ($f in $files) {
            $rel = $f.FullName.Substring($stage.Length).TrimStart('\', '/')
            $dest = Join-Path $install $rel
            if (Test-Path -LiteralPath $dest) {
                $bak = Join-Path $backup $rel
                New-Item -ItemType Directory -Force -Path (Split-Path -Parent $bak) | Out-Null
                Copy-Item -LiteralPath $dest -Destination $bak -Force
            }
            New-Item -ItemType Directory -Force -Path (Split-Path -Parent $dest) | Out-Null
            Copy-Item -LiteralPath $f.FullName -Destination $dest -Force
            $updated.Add($rel) | Out-Null
        }
    } catch {
        foreach ($rel in $updated) {
            $bak = Join-Path $backup $rel
            $dest = Join-Path $install $rel
            if (Test-Path -LiteralPath $bak) { Copy-Item -LiteralPath $bak -Destination $dest -Force }
        }
        Fail "替换失败，已回滚：$($_.Exception.Message)"
    }

    $newVersion = Get-VersionFile (Join-Path $install 'VERSION.txt')
    Trace "COPIED version=$newVersion files=$($updated.Count)"
    Write-Host "UPDATE: OK installed=$newVersion files=$($updated.Count)" -ForegroundColor Green
    if ($wasRunning -and -not $NoRestart) {
        Trace 'RESTART'
        Start-Process -FilePath $exePath -WorkingDirectory $install | Out-Null
        Write-Host 'UPDATE: OK restarted'
    }
    Trace 'DONE'
}
finally {
    Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
}
