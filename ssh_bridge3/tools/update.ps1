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
    [string]$InstallDir = '',
    [switch]$CheckOnly,
    [switch]$NoRestart
)

$here = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
if (-not $InstallDir) { $InstallDir = Join-Path $here '..' }

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
Add-Type -AssemblyName System.IO.Compression.FileSystem

function Fail([string]$msg) {
    Write-Host "UPDATE: FAIL $msg" -ForegroundColor Red
    exit 1
}

function FetchText([string]$uri) {
    for ($i = 1; $i -le 3; $i++) {
        try {
            return (Invoke-WebRequest -UseBasicParsing -Uri $uri -TimeoutSec 60).Content
        } catch {
            if ($i -eq 3) { throw }
            Write-Host "UPDATE: retry manifest ($i/3): $($_.Exception.Message)"
            Start-Sleep -Seconds 2
        }
    }
}

function FetchFile([string]$uri, [string]$outFile) {
    for ($i = 1; $i -le 3; $i++) {
        try {
            Invoke-WebRequest -UseBasicParsing -Uri $uri -OutFile $outFile -TimeoutSec 180
            return
        } catch {
            if ($i -eq 3) { throw }
            Write-Host "UPDATE: retry package ($i/3): $($_.Exception.Message)"
            Start-Sleep -Seconds 2
        }
    }
}

function Get-VersionFile([string]$path) {
    if (-not (Test-Path -LiteralPath $path)) { return '0.0.0' }
    foreach ($line in Get-Content -LiteralPath $path) {
        if ($line -match '^\s*version\s*=\s*(.+?)\s*$') { return $Matches[1] }
    }
    return '0.0.0'
}

function Compare-Ver([string]$a, [string]$b) {
    $a = $a.Trim().TrimStart('v', 'V')
    $b = $b.Trim().TrimStart('v', 'V')
    $aParts = $a -split '-', 2
    $bParts = $b -split '-', 2
    $aBase = $aParts[0]
    $bBase = $bParts[0]
    try { $av = [version]$aBase } catch { $av = [version]'0.0.0' }
    try { $bv = [version]$bBase } catch { $bv = [version]'0.0.0' }
    if ($av -gt $bv) { return 1 }
    if ($av -lt $bv) { return -1 }
    $as = if ($aParts.Count -gt 1) { $aParts[1] } else { '' }
    $bs = if ($bParts.Count -gt 1) { $bParts[1] } else { '' }
    if ($as -eq $bs) { return 0 }
    if ($as -eq '') { return 1 }
    if ($bs -eq '') { return -1 }
    $c = [string]::CompareOrdinal($as, $bs)
    if ($c -gt 0) { return 1 }
    if ($c -lt 0) { return -1 }
    return 0
}

$install = (Resolve-Path -LiteralPath $InstallDir).Path
$exePath = Join-Path $install 'ssh_bridge3.exe'
if (-not (Test-Path -LiteralPath $exePath)) { Fail "安装目录缺少 ssh_bridge3.exe：$install" }
$versionPath = Join-Path $install 'VERSION.txt'
$localVersion = Get-VersionFile $versionPath
Write-Host "UPDATE: install=$install current=$localVersion"

$isHttp = $Manifest -match '^https?://'
$manifestDir = ''
if ($isHttp) {
    try {
        $text = FetchText $Manifest
    } catch { Fail "下载清单失败：$($_.Exception.Message)" }
} else {
    if (-not (Test-Path -LiteralPath $Manifest)) { Fail "清单不存在：$Manifest" }
    $manifestPath = (Resolve-Path -LiteralPath $Manifest).Path
    $manifestDir = Split-Path -Parent $manifestPath
    $text = Get-Content -LiteralPath $manifestPath -Raw
}

try { $m = $text | ConvertFrom-Json } catch { Fail '清单不是合法 JSON' }
if (-not $m.version -or (-not $m.zip -and -not $m.url) -or -not $m.sha256) {
    Fail '清单缺少 version / (zip 或 url) / sha256'
}

$cmp = Compare-Ver $m.version $localVersion
Write-Host "UPDATE: remote=$($m.version)"
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
    if ($zipIsUrl -or $isHttp) {
        $zipUri = if ($zipIsUrl) { [Uri]$zipRef } else { [Uri]::new([Uri]$Manifest, $zipRef) }
        if ($zipUri.Scheme -notin @('http', 'https')) { Fail "不支持的下载协议：$($zipUri.Scheme)" }
        $zipPath = Join-Path $tmp 'package.zip'
        try {
            FetchFile $zipUri.AbsoluteUri $zipPath
        } catch { Fail "下载更新包失败：$($_.Exception.Message)" }
    } else {
        $localZip = if ([System.IO.Path]::IsPathRooted($zipRef)) { $zipRef } else { Join-Path $manifestDir $zipRef }
        if (-not (Test-Path -LiteralPath $localZip)) { Fail "更新包不存在：$localZip" }
        $zipPath = Join-Path $tmp 'package.zip'
        Copy-Item -LiteralPath $localZip -Destination $zipPath -Force
    }

    $wantZip = ([string]$m.sha256 -split '\s+')[0].ToUpperInvariant()
    $wantSize = if ($m.size_bytes) { [int64]$m.size_bytes } else { 0 }
    $zipOk = $false
    for ($attempt = 1; $attempt -le 3; $attempt++) {
        if ($attempt -gt 1 -and $zipUri) {
            Remove-Item -Force $zipPath -ErrorAction SilentlyContinue
            try { FetchFile $zipUri.AbsoluteUri $zipPath } catch { Fail "下载更新包失败：$($_.Exception.Message)" }
        }
        $gotSize = (Get-Item -LiteralPath $zipPath).Length
        $gotZip = (Get-FileHash -LiteralPath $zipPath -Algorithm SHA256).Hash.ToUpperInvariant()
        if (($wantSize -eq 0 -or $gotSize -eq $wantSize) -and $wantZip -eq $gotZip) {
            $zipOk = $true
            break
        }
        Write-Host "UPDATE: zip integrity retry ($attempt/3) size=$gotSize expect=$wantSize sha=$gotZip"
        Start-Sleep -Seconds 2
    }
    if (-not $zipOk) { Fail "zip SHA-256/大小校验失败：期望 $wantZip" }
    Write-Host 'UPDATE: OK zip-sha256'

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
    if (-not (Test-Path -LiteralPath $stagedExe)) { Fail '更新包缺少 ssh_bridge3.exe' }
    if (-not (Test-Path -LiteralPath (Join-Path $stage 'VERSION.txt'))) { Fail '更新包缺少 VERSION.txt' }
    if ($m.exe_sha256) {
        $gotExe = (Get-FileHash -LiteralPath $stagedExe -Algorithm SHA256).Hash.ToUpperInvariant()
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
    Write-Host "UPDATE: OK installed=$newVersion files=$($updated.Count)" -ForegroundColor Green
    if ($wasRunning -and -not $NoRestart) {
        Start-Process -FilePath $exePath -WorkingDirectory $install | Out-Null
        Write-Host 'UPDATE: OK restarted'
    }
}
finally {
    Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
}
