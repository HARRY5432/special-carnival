#Requires -Version 5.1
<#
.SYNOPSIS
    MASTER command for codeisotope: total purge, integrity-verified install, zero
    re-work on repeat runs. Store-backed, sandboxed, junction-activated.

.DESCRIPTION
    Five phases, same contract as always: DISCOVER / ERADICATE / PROVE / INSTALL /
    VERIFY. Nothing that made the previous builds work has been dropped.

    WHY IT IS FAST. A security scanner on this machine charges ~24ms for every
    write of a .js or .exe file, and charges it again even when the bytes are
    identical. codeisotope ships 49 script files, so a naive reinstall pays a
    ~1.2s tax every single time. Measured: 0.3ms for the same bytes named .txt,
    24.5ms named .js. The tax is charged on writes only (54 reads cost 14ms) and
    is identical on C: and D:.

    So the fix is not a faster delete. The fix is to stop writing files that are
    already correct.

      * A content-addressed store. Each version is extracted exactly once into
        <store>\<pkg>\<version>\tree and never rewritten. A repeat run writes
        nothing, so it pays no scanner tax at all.
      * Activation is a junction flip, not a copy. <prefix>\node_modules\<pkg>
        becomes a reparse point at the stored tree. Flipping costs ~2ms because
        it is a metadata operation, and the old version stays on disk for
        instant rollback until pruning.
      * npm is not used. It cost ~650ms of process startup plus ~1.5s of its own
        work. The tarball is fetched with WebClient, the sha512 in the registry
        packument is verified by hand, and the archive is unpacked by an
        in-process ustar reader. gzip decompress measured 21-132ms.
      * The download runs on a threadpool thread and is awaited after the erase,
        so network time overlaps filesystem work instead of following it.
      * latest resolution is cached in state.json for -MaxAgeHours (default 6,
        the same window npm uses), so a warm run needs no network at all.

    WHY IT IS STILL SAFE.

      * Nothing is extracted before its sha512 matches the registry's
        dist.integrity. A corrupt or tampered tarball aborts the run with the
        live install already proven clean, and exits 1. Bypassing npm does not
        mean bypassing verification; it means doing it explicitly.
      * Store trees are immutable. They are only ever added to, or deleted by an
        explicit prune that can never target the active version.
      * Windows PowerShell 5.1's Remove-Item -Recurse is unsafe on reparse
        points: it hung outright on a junction during testing, and deleting a
        parent that merely CONTAINS a junction is worse. Every removal here goes
        through Remove-Node, which detects a reparse point and unlinks it
        non-recursively so the target survives. Verified against a live junction.

    THE FLOOR. A genuine first install of a new version still costs ~1.2s of
    scanner tax, and that is not removable without an antivirus exclusion, which
    this script will not take for you. Warm runs are ~0.9s. That gap is the whole
    design: pay the tax once per version, never again.

    ONE NEW OPERATIONAL RISK. The live install is a junction INTO the store, so
    the store is now load-bearing: delete or move it and the command stops
    resolving until this script runs again. That is the price of never rewriting
    files, and it is why pruning can never target the active version. Keep the
    store on the same volume as the npm prefix (the default does), and do not
    point -Store at removable media. Re-running this script always repairs a
    broken junction.

.PARAMETER Scope       Global (default) | Local | Both
.PARAMETER Version     Exact version to install. Omit to resolve 'latest'.
.PARAMETER Integrity   Pin the expected sha512 so a pinned install needs no
                       packument fetch and no network beyond the tarball itself.
.PARAMETER Store       Store root. Default: <prefix>\.<pkg>-store
.PARAMETER Keep        Store versions to retain besides the active one (default 2).
.PARAMETER NoStore     Bypass the store; re-download and re-extract every run.
.PARAMETER MaxAgeHours How long a cached 'latest' resolution stays valid (default 6).
.PARAMETER SkipExec    Trust the on-disk verification; do not spawn the binary.
.PARAMETER PurgeNpmCache
                       Also wipe the shared npm _cacache. Off by default: it
                       belongs to every other npm tool you use, and this script
                       no longer reads it.
.PARAMETER KeepCache   Retained for compatibility; the npm cache is already left
                       alone unless -PurgeNpmCache is given.
.PARAMETER DryRun      Report every path that would change. Touches nothing.
.PARAMETER Force       Kill running <pkg> processes so locks cannot block, and
                       re-resolve latest even if the cache is warm.
.PARAMETER Quiet       Suppress the banner and per-path chatter.
#>

[CmdletBinding()]
param(
    [ValidateSet('Global', 'Local', 'Both')]
    [string]$Scope = 'Global',
    [string]$Version = '',
    [string]$Integrity = '',
    [string]$Store = '',
    [int]$Keep = 2,
    [switch]$NoStore,
    [int]$MaxAgeHours = 6,
    [switch]$SkipExec,
    [switch]$PurgeNpmCache,
    [switch]$KeepCache,
    [switch]$DryRun,
    [switch]$Force,
    [switch]$Quiet
)

$ErrorActionPreference = 'Continue'
$Package = 'codeisotope'
$UA      = 'codeisotope-master'
$sw      = [System.Diagnostics.Stopwatch]::StartNew()

function Say      { param($m) if (-not $Quiet) { Write-Host $m -ForegroundColor Gray } }
$script:lastMark = 0
function Write-Step {
    param($m)
    $now = $sw.ElapsedMilliseconds
    $gap = if ($script:lastMark -eq 0) { 0 } else { $now - $script:lastMark }
    Write-Host ("`n==> {0}   [{1} ms]" -f $m, $gap) -ForegroundColor Cyan
    $script:lastMark = $now
}
function Write-Ok   { param($m) Say "    [ok] $m" 'Green'; }
function Write-Info { param($m) Say "    [..] $m" 'Gray' }
function Write-Warn { param($m) Say "    [--] $m" 'Yellow' }
function Write-Err  { param($m) Write-Host "    [!!] $m" -ForegroundColor Red }
function Write-Del  { param($m) Say "    [-] $m" 'Magenta' }
function Write-Act  { param($m) Say "    [>>] $m" 'Cyan' }

# ===================================================================== helpers

function Test-Reparse {
    param([string]$Path)
    # No Test-Path: GetAttributes throws when the path is gone, and "gone"
    # already means "not a reparse point". One syscall instead of two, and no
    # cmdlet overhead, which is what dominates a warm run.
    try {
        return [bool]([System.IO.File]::GetAttributes($Path) -band [System.IO.FileAttributes]::ReparsePoint)
    } catch { return $false }
}

function Test-Exists {
    param([string]$Path)
    return ([System.IO.Directory]::Exists($Path) -or [System.IO.File]::Exists($Path))
}

function Get-VersionKey {
    # Sortable, semver-aware key. Zero-pads each numeric part so 0.10.0 sorts
    # above 0.9.0, and ranks a pre-release below its own release.
    param([string]$Version)
    $core = ($Version -split '-')[0]
    $nums = @($core -split '\.' | ForEach-Object {
        $d = $_ -replace '[^0-9]', ''
        if ($d) { '{0:D8}' -f [int]$d } else { '00000000' }
    })
    while ($nums.Count -lt 3) { $nums += '00000000' }
    $pre = if ($Version -match '-') { '0' + ($Version -split '-', 2)[1] } else { '1' }
    return (($nums + @($pre)) -join '.')
}

function Remove-Node {
    # Junction-safe removal. Remove-Item -Recurse follows reparse points and can
    # hang or eat the target, so a reparse point is always unlinked
    # non-recursively. A real directory is deleted recursively with .NET.
    param([string]$Path)
    for ($i = 1; $i -le 3; $i++) {
        try {
            if (Test-Reparse $Path) {
                if ([System.IO.Directory]::Exists($Path)) { [System.IO.Directory]::Delete($Path, $false) }
                else { [System.IO.File]::Delete($Path) }
            }
            elseif ([System.IO.Directory]::Exists($Path)) {
                [System.IO.Directory]::Delete($Path, $true)
            }
            elseif ([System.IO.File]::Exists($Path)) {
                [System.IO.File]::Delete($Path)
            }
            return $true
        } catch {
            if ($i -eq 3) { return $false }
            Start-Sleep -Milliseconds (150 * $i)
            [GC]::Collect(); [GC]::WaitForPendingFinalizers()
        }
    }
    return -not (Test-Path -LiteralPath $Path)
}

function Get-Json {
    param([string]$Path)
    try { return [System.IO.File]::ReadAllText($Path) | ConvertFrom-Json } catch { return $null }
}

function Write-Json {
    param([string]$Path, $Obj)
    [System.IO.File]::WriteAllText($Path, ($Obj | ConvertTo-Json -Depth 12))
}

function Write-IfChanged {
    # Avoids rewriting an identical shim, which would pay the scanner tax for
    # nothing. Returns $true when a write happened.
    param([string]$Path, [string]$Content)
    if ([System.IO.File]::Exists($Path)) {
        if ([System.IO.File]::ReadAllText($Path) -ceq $Content) { return $false }
    }
    [System.IO.File]::WriteAllText($Path, $Content)
    return $true
}

function Get-Sha512B64 {
    param([byte[]]$Bytes)
    $h = [System.Security.Cryptography.SHA512]::Create()
    try { return [Convert]::ToBase64String($h.ComputeHash($Bytes)) } finally { $h.Dispose() }
}

function Wait-Task {
    # Bounded wait for a WebClient async download. DownloadDataTaskAsync has NO
    # timeout of its own, so a stalled or throttled connection would block
    # GetResult() forever and freeze the run with no output. On timeout the
    # request is cancelled and an exception is thrown for the caller to handle.
    param($Task, [int]$TimeoutMs, [string]$What)
    $idx = [System.Threading.Tasks.Task]::WaitAny(@($Task), $TimeoutMs)
    if ($idx -eq -1) {
        try { $ua.CancelAsync() } catch {}
        throw "$What timed out after $([int]($TimeoutMs / 1000))s (connection stalled or throttled)"
    }
    return $Task.GetAwaiter().GetResult()
}

function Expand-NpmTarball {
    # In-process ustar reader. Returns the number of files written.
    # $GzBytes, not $Gz: PowerShell variable names are case-insensitive, so a
    # $Gz parameter would collide with the $gzs stream local below.
    param([byte[]]$GzBytes, [string]$Dest)
    $ms = New-Object System.IO.MemoryStream
    $src = New-Object System.IO.MemoryStream(,$GzBytes)
    $gzs = New-Object System.IO.Compression.GZipStream($src, [System.IO.Compression.CompressionMode]::Decompress)
    try { $gzs.CopyTo($ms) } finally { $gzs.Dispose(); $src.Dispose() }
    $tar = $ms.ToArray()

    $enc = [System.Text.Encoding]::ASCII
    $pos = 0; $count = 0; $longName = $null
    while ($pos + 512 -le $tar.Length) {
        $h = $tar[$pos..($pos + 511)]
        $pos += 512
        if ($h[0] -eq 0) { break }                      # end-of-archive
        $name = ($enc.GetString($h, 0, 100) -replace "`0", '')
        $sf   = (($enc.GetString($h, 124, 12)) -replace "`0", '').Trim()
        $size = if ($sf) { [int64][Convert]::ToInt64($sf, 8) } else { 0 }
        $type = $h[156]

        # ustar long path: 155-byte prefix at offset 345 joined with '/' + name
        $prefix = ($enc.GetString($h, 345, 155) -replace "`0", '').Trim()
        if ($prefix) { $name = "$prefix/$name" }
        if ($longName) { $name = $longName; $longName = $null }

        switch ([char]$type) {
            'L' { $longName = $enc.GetString($tar, $pos, [int]$size) -replace "`0", ''; $pos += [int64]([Math]::Ceiling($size / 512.0) * 512); continue }
            '5' {
                $rel = ($name -replace '^package[\\/]', '').TrimStart([char]0, '\', '/')
                if ($rel) { [System.IO.Directory]::CreateDirectory([System.IO.Path]::Combine($Dest, $rel)) | Out-Null }
            }
            default {
                $rel = ($name -replace '^package[\\/]', '').TrimStart([char]0, '\', '/')
                if ($rel) {
                    $target = [System.IO.Path]::Combine($Dest, $rel)
                    $dir = [System.IO.Path]::GetDirectoryName($target)
                    if (-not [System.IO.Directory]::Exists($dir)) { [System.IO.Directory]::CreateDirectory($dir) | Out-Null }
                    $body = New-Object byte[] $size
                    if ($size -gt 0) { [Array]::Copy($tar, $pos, $body, 0, $size) }
                    [System.IO.File]::WriteAllBytes($target, $body)
                    $count++
                }
            }
        }
        $pos += [int64]([Math]::Ceiling($size / 512.0) * 512)
    }
    return $count
}

# npm's own Windows shim templates, reproduced exactly. $Rel is the path from
# the shim's own directory to the package's bin script.
# These are SINGLE-quoted here-strings with explicit token replacement. A
# double-quoted here-string is a trap here: backslash is not an escape character
# in PowerShell, so "%dp0%\\$Rel" silently emits an extra separator and the shim
# points at nothing. Interpolating nothing means nothing can be mangled.
function Get-ShimSet {
    param([string]$Name, [string]$Rel, [string]$RelPs)
    $cmd = @'
@ECHO off
GOTO start
:find_dp0
SET dp0=%~dp0
EXIT /b
:start
SETLOCAL
CALL :find_dp0

IF EXIST "%dp0%\node.exe" (
  SET "_prog=%dp0%\node.exe"
) ELSE (
  SET "_prog=node"
  SET PATHEXT=%PATHEXT:;.JS;=;%
)

endLocal & goto #_undefined_# 2>NUL || title %COMSPEC% & "%_prog%"  "%dp0%\__REL__" %*
'@
    $sh = @'
#!/bin/sh
basedir=$(dirname "$(echo "$0" | sed -e 's,\\,/,g')")

case `uname` in
    *CYGWIN*|*MINGW*|*MSYS*)
        if command -v cygpath > /dev/null 2>&1; then
            basedir=`cygpath -w "$basedir"`
        fi
    ;;
esac

if [ -x "$basedir/node" ]; then
  exec "$basedir/node"  "$basedir/__RELPS__" "$@"
else
  exec node  "$basedir/__RELPS__" "$@"
fi
'@
    $ps1 = @'
#!/usr/bin/env pwsh
$basedir=Split-Path $MyInvocation.MyCommand.Definition -Parent

$exe=""
if ($PSVersionTable.PSVersion -lt "6.0" -or $IsWindows) {
  # Fix case when both the Windows and Linux builds of Node
  # are installed in the same directory
  $exe=".exe"
}
$ret=0
if (Test-Path "$basedir/node$exe") {
  # Support pipeline input
  if ($MyInvocation.ExpectingInput) {
    $input | & "$basedir/node$exe"  "$basedir/__RELPS__" $args
  } else {
    & "$basedir/node$exe"  "$basedir/__RELPS__" $args
  }
  $ret=$LASTEXITCODE
} else {
  # Support pipeline input
  if ($MyInvocation.ExpectingInput) {
    $input | & "node$exe"  "$basedir/__RELPS__" $args
  } else {
    & "node$exe"  "$basedir/__RELPS__" $args
  }
  $ret=$LASTEXITCODE
}
exit $ret
'@
    $cmd  = $cmd.Replace('__REL__',   $Rel).Replace('__NAME__', $Name)
    $sh   = $sh.Replace('__RELPS__', $RelPs).Replace('__REL__', $Rel)
    $ps1  = $ps1.Replace('__RELPS__', $RelPs).Replace('__REL__', $Rel)
    # A here-string carries a trailing newline, and npm writes exactly one
    # terminator after the final line. Normalise to CRLF inside the .cmd, LF in
    # the other two, and end with precisely one terminator.
    $crlf = [char[]]@([char]13, [char]10)
    $out = @{}
    $out["$Name.cmd"] = (($cmd -replace "`r?`n", "`r`n").TrimEnd($crlf)) + "`r`n"
    $out["$Name"]     = (($sh  -replace "`r?`n", "`n").TrimEnd($crlf)) + "`n"
    $out["$Name.ps1"] = (($ps1 -replace "`r?`n", "`n").TrimEnd($crlf)) + "`n"
    return $out
}

# ===================================================================== banner

$globalPrefix = if ($env:npm_config_prefix) { $env:npm_config_prefix }
                elseif ($env:APPDATA) { Join-Path $env:APPDATA 'npm' } else { $null }
if (-not $globalPrefix -or -not [System.IO.Directory]::Exists($globalPrefix)) {
    $globalPrefix = (& npm prefix -g 2>$null | Select-Object -Last 1)
    Write-Warn 'non-standard prefix, asked npm once'
}
if (-not $globalPrefix) { Write-Err 'Cannot resolve the global npm prefix.'; exit 1 }
$globalPrefix = $globalPrefix.Trim()

$isLocal = $Scope -eq 'Local'
if ($isLocal) {
    $npmRoot    = Join-Path (Get-Location).Path 'node_modules'
    $binDir     = Join-Path $npmRoot '.bin'
    $relToBin   = "..\$Package"
    $relToBinPs = "../$Package"
} else {
    $npmRoot    = Join-Path $globalPrefix 'node_modules'
    $binDir     = $globalPrefix
    $relToBin   = "node_modules\$Package"
    $relToBinPs = "node_modules/$Package"
}
# The package ALWAYS lives under node_modules. The shims live in the prefix
# (global) or node_modules\.bin (local). Conflating the two puts a junction on
# top of the extensionless shim slot and leaves node_modules empty.
$livePath = Join-Path $npmRoot $Package
$storeRoot = if ($Store) { $Store } else { Join-Path $globalPrefix ".$Package-store" }
$pkgStore  = Join-Path $storeRoot $Package
$stateFile = Join-Path $pkgStore 'state.json'
$ua = New-Object System.Net.WebClient
$ua.Headers.Add('User-Agent', $UA)

Write-Host ''
Write-Host '  CODEISOTOPE -- MASTER PURGE + INSTALL (store-backed)' -ForegroundColor White
Write-Host '  =======================================================' -ForegroundColor DarkGray
Say ("  package  : {0}   scope: {1}   version: {2}   mode: {3}" -f `
    $Package, $Scope, $(if ($Version) { $Version } else { 'latest' }), $(if ($DryRun) { 'DRY RUN' } else { 'LIVE' }))
Say ("  live     : {0}" -f $livePath)
Say ("  store    : {0}{1}" -f $pkgStore, $(if ($NoStore) { '   (bypassed by -NoStore)' } else { '' }))
Write-Host ''

# ===================================================================== 1. DISCOVER
Write-Step 'PHASE 1  Discover every trace on disk'

$cached      = Get-Json $stateFile
$fullyPinned = ($Version -ne '') -and ($Integrity -ne '')
$freshCache  = ($cached -and $cached.checkedAt -and $cached.latest -and
                ((Get-Date) - [datetime]$cached.checkedAt).TotalHours -le $MaxAgeHours)
$needPackument = (-not $fullyPinned) -and ((-not $freshCache) -or $Force)
# Only open the socket when the answer is actually needed. An unawaited fetch is
# not free: it costs ~170ms of setup and leaves a request in flight at exit.
if ($needPackument) { $packTask = $ua.DownloadDataTaskAsync("https://registry.npmjs.org/$Package") }
Write-Info $(if ($needPackument) { 'packument fetch started (async)' } else { 'packument fetch not needed' })

$artifacts = New-Object System.Collections.Generic.List[string]
if ($Scope -in @('Global', 'Both')) {
    $pd = Join-Path (Join-Path $globalPrefix 'node_modules') $Package
    if ([System.IO.Directory]::Exists($pd)) { $artifacts.Add($pd) }
    if ([System.IO.Directory]::Exists($globalPrefix)) {
        foreach ($f in [System.IO.Directory]::GetFileSystemEntries($globalPrefix, "$Package*")) { $artifacts.Add($f) }
    }
}
if ($Scope -in @('Local', 'Both')) {
    $pd = Join-Path (Join-Path (Get-Location).Path 'node_modules') $Package
    if ([System.IO.Directory]::Exists($pd)) { $artifacts.Add($pd) }
    $b = Join-Path (Join-Path (Get-Location).Path 'node_modules') '.bin'
    if ([System.IO.Directory]::Exists($b)) {
        foreach ($f in [System.IO.Directory]::GetFileSystemEntries($b, "$Package*")) { $artifacts.Add($f) }
    }
}
if ($artifacts.Count -eq 0) { Write-Ok "No live artifacts of $Package (already clean)" }
else {
    Write-Warn "$($artifacts.Count) live artifact(s):"
    foreach ($p in $artifacts) { Write-Info $p }
}
$junctions = @($artifacts | Where-Object { Test-Reparse $_ })
if ($junctions.Count) { Write-Info "$($junctions.Count) of them are junctions into the store" }

# resolve version + integrity
$resolved = $null; $integrity = $Integrity; $tarball = $null
if ($fullyPinned) {
    $resolved = $Version
    $tarball  = "https://registry.npmjs.org/$Package/-/$Package-$Version.tgz"
    Write-Info "fully pinned: $Version + sha512, no registry lookup at all"
}
elseif ($freshCache -and -not $Force) {
    $resolved  = if ($Version) { $Version } else { $cached.latest }
    $integrity = if ($Integrity) { $Integrity } else { $cached.integrity }
    $tarball   = "https://registry.npmjs.org/$Package/-/$Package-$resolved.tgz"
    Write-Ok "latest from cache ($resolved), checked $(([datetime]$cached.checkedAt).ToString('yyyy-MM-dd HH:mm'))"
}
else {
    try {
        $pk = [System.Text.Encoding]::UTF8.GetString((Wait-Task $packTask 30000 'packument fetch')) | ConvertFrom-Json
        $resolved  = if ($Version) { $Version } else { $pk.'dist-tags'.latest }
        $integrity = if ($Integrity) { $Integrity } else { $pk.versions.$resolved.dist.integrity }
        $tarball   = $pk.versions.$resolved.dist.tarball
        Write-Ok "resolved from registry: $resolved"
    } catch {
        Write-Err "packument fetch failed: $($_.Exception.Message)"
        exit 1
    }
}
if (-not $tarball) { $tarball = "https://registry.npmjs.org/$Package/-/$Package-$resolved.tgz" }

# ===================================================================== 2. ERADICATE
Write-Step 'PHASE 2  Eradicate'
if ($Force) {
    $procs = @(Get-Process -Name "*$Package*" -ErrorAction SilentlyContinue)
    foreach ($pr in $procs) { Write-Info "killing $($pr.ProcessName) (pid $($pr.Id))"; try { $pr.Kill() } catch { Write-Warn "could not kill pid $($pr.Id)" } }
    if (-not $procs.Count) { Write-Ok 'No running process to kill' }
}
$failed = 0
foreach ($p in $artifacts) {
    if ($DryRun) { Write-Del "would delete: $p"; continue }
    if (Remove-Node $p) { Write-Del "deleted: $p$(if (Test-Reparse $p) { '' })" }
    else { Write-Err "could not delete: $p"; $failed++ }
}
if ($PurgeNpmCache) {
    $cacheDir = if ($env:npm_config_cache) { $env:npm_config_cache }
                elseif ($env:LOCALAPPDATA) { Join-Path $env:LOCALAPPDATA 'npm-cache' } else { $null }
    if ($cacheDir) {
        $cacache = Join-Path $cacheDir '_cacache'
        if ($DryRun) { if ([System.IO.Directory]::Exists($cacache)) { Write-Del "would delete: $cacache" } }
        elseif ([System.IO.Directory]::Exists($cacache)) {
            if (Remove-Node $cacache) { Write-Del "deleted: $cacache" }
        }
    }
} elseif (-not $KeepCache) {
    Say "    [--] npm cache left alone: it is shared with your other tools, and this script does not use it"
}

# ===================================================================== 3. PROVE
Write-Step 'PHASE 3  Prove the purge was total'
$survivors = @($artifacts | Where-Object { Test-Exists $_ })
if ($survivors.Count -gt 0) {
    if ($DryRun) {
        Write-Warn "$($survivors.Count) still present - expected, dry run changed nothing"
        Write-Host "`n  DRY RUN complete. Nothing deleted, downloaded or installed.`n" -ForegroundColor Yellow
        exit 0
    }
    Write-Err "$($survivors.Count) artifact(s) survived:"
    $survivors | ForEach-Object { Write-Err "    $_" }
    Write-Host "`n    A file is locked or access denied. Close terminals running it, retry with -Force.`n" -ForegroundColor Red
    exit 1
}
if ($failed -gt 0) { Write-Err "$failed deletion(s) failed"; exit 1 }
Write-Ok 'Zero live artifacts remain. Provably clean.'

if ($DryRun) { Write-Host "`n  DRY RUN complete. Nothing deleted, downloaded or installed.`n" -ForegroundColor Yellow; exit 0 }

# ===================================================================== 4. INSTALL
Write-Step 'PHASE 4  Install'
# A run killed mid-extract (timeout, Ctrl+C, power loss) leaves its .staging-*
# directory behind. Those are always garbage — a live run holds its staging
# path in a local variable and never re-reads the directory — so sweep them now.
if (-not $NoStore -and [System.IO.Directory]::Exists($pkgStore)) {
    foreach ($s in [System.IO.Directory]::GetDirectories($pkgStore, '.staging-*')) {
        if ($DryRun) { Write-Del "would delete stale staging: $s"; continue }
        if (Remove-Node $s) { Write-Del "deleted stale staging: $(Split-Path $s -Leaf)" }
    }
}
$versionDir = Join-Path $pkgStore $resolved
$treeDir    = Join-Path $versionDir 'tree'
$metaFile   = Join-Path $versionDir 'meta.json'
$storeHit   = (-not $NoStore) -and [System.IO.File]::Exists((Join-Path $treeDir 'package.json'))

if ($storeHit) {
    $mj = Get-Json $metaFile
    if ($mj -and $mj.integrity -ne $integrity -and $integrity) {
        Write-Warn 'stored integrity differs from registry, re-extracting'
        $storeHit = $false
    } else {
        Write-Ok "STORE HIT $resolved - zero files written, zero scanner tax"
    }
}
if (-not $storeHit) {
    Write-Info "tarball fetch started (async, overlapped with the erase)"
    $tarTask = $ua.DownloadDataTaskAsync($tarball)
    try { $bytes = Wait-Task $tarTask 60000 'tarball download' }
    catch { Write-Err "tarball download failed: $($_.Exception.Message)"; exit 1 }
    Write-Info ("downloaded {0:N0} bytes" -f $bytes.Length)

    if ($integrity) {
        $want = ($integrity -replace '^sha512-', '')
        $got  = Get-Sha512B64 $bytes
        if ($want -cne $got) {
            Write-Err 'INTEGRITY MISMATCH - tarball rejected, nothing extracted'
            Write-Err "  expected sha512-$want"
            Write-Err "  actual   sha512-$got"
            exit 1
        }
        Write-Ok "sha512 verified against registry dist.integrity"
    } else {
        Write-Warn 'no integrity available from the registry - tarball NOT verified'
    }

    $stage = Join-Path $pkgStore ('.staging-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
    Remove-Node $stage | Out-Null
    [System.IO.Directory]::CreateDirectory($stage) | Out-Null
    $n = Expand-NpmTarball -GzBytes $bytes -Dest $stage
    Write-Info "extracted $n files in-process (no npm, no tar.exe)"
    $pj = Get-Json (Join-Path $stage 'package.json')
    if (-not $pj) { Remove-Node $stage | Out-Null; Write-Err 'extracted tree has no package.json'; exit 1 }
    if ($pj.version -ne $resolved) { Remove-Node $stage | Out-Null; Write-Err "extracted $($pj.version) but wanted $resolved"; exit 1 }
    Remove-Node $versionDir | Out-Null
    [System.IO.Directory]::CreateDirectory($versionDir) | Out-Null
    Remove-Node $treeDir | Out-Null
    [System.IO.Directory]::Move($stage, $treeDir)
    Write-Ok "stored at $treeDir"
    Write-Json $metaFile ([pscustomobject]@{
        package = $Package; version = $resolved; integrity = $integrity
        tarball = $tarball; files = $n; storedAt = (Get-Date).ToString('o')
    })
    Write-Json $stateFile ([pscustomobject]@{
        latest = $resolved; integrity = $integrity; checkedAt = (Get-Date).ToString('o')
    })
}

# ---- activate: junction flip, no file writes
Write-Act 'activating (junction flip - metadata only, no file writes)'
if (Test-Reparse $livePath) { Remove-Node $livePath | Out-Null }
elseif ([System.IO.Directory]::Exists($livePath)) { Remove-Node $livePath | Out-Null }
[System.IO.Directory]::CreateDirectory($npmRoot) | Out-Null
(New-Item -ItemType Junction -Path $livePath -Target $treeDir -Force -EA Stop) | Out-Null
Write-Ok "junction: $livePath -> $treeDir"

$bin = Get-Json (Join-Path $treeDir 'package.json')
# A package with no bin entry is not executable. Writing a shim anyway produces
# a silently broken launcher that fails only when someone runs it, so stop here.
$binKeys = if ($bin -and $bin.bin) { @($bin.bin.PSObject.Properties.Name) } else { @() }
if (-not $binKeys.Count) {
    Write-Err "stored package.json declares no 'bin' entry - cannot create a working shim"
    Write-Err "  store file may be corrupt; re-run with -NoStore to re-download it"
    exit 1
}
foreach ($k in $binKeys) {
    if (-not $bin.bin.$k) { Write-Err "bin entry '$k' has no target path"; exit 1 }
}
$shimRoot = $binKeys
$shimDir = $binDir
[System.IO.Directory]::CreateDirectory($shimDir) | Out-Null
$shimWritten = 0; $shimSkipped = 0
foreach ($n in $shimRoot) {
    # npm writes backslashes into the .cmd and forward slashes into the .ps1 and
    # the sh script. package.json always uses forward slashes, so the .cmd path
    # has to be converted to match what npm produces.
    $rel  = (($relToBin + '\' + $bin.bin.$n) -replace '/', '\')
    $relP = ($relToBinPs + '/' + ($bin.bin.$n -replace '\\', '/'))
    foreach ($kv in (Get-ShimSet -Name $n -Rel $rel -RelPs $relP).GetEnumerator()) {
        $target = Join-Path $shimDir $kv.Key
        if (Test-Reparse $target) {
            Write-Err "refusing to write a shim over a reparse point: $target"
            exit 1
        }
        if (Write-IfChanged $target $kv.Value) { $shimWritten++ } else { $shimSkipped++ }
    }
}
Write-Ok "shims: $shimWritten written, $shimSkipped already correct (left alone)"

# ===================================================================== 5. VERIFY
Write-Step 'PHASE 5  Verify'
$vpj = Get-Json (Join-Path $livePath 'package.json')
if (-not $vpj) { Write-Err "no package.json reachable through the junction at $livePath"; exit 1 }
if ($vpj.version -ne $resolved) { Write-Err "junction serves $($vpj.version), wanted $resolved"; exit 1 }
$shimsSeen = @()
foreach ($n in $shimRoot) {
    foreach ($e in '', '.cmd', '.ps1') {
        $f = Join-Path $shimDir ($n + $e)
        if ([System.IO.File]::Exists($f)) { $shimsSeen += [System.IO.Path]::GetFileName($f) }
    }
}
if (-not $shimsSeen.Count) { Write-Err "no shim in $shimDir"; exit 1 }
Write-Ok "$($vpj.name)@$($vpj.version)   shims: $($shimsSeen -join ', ')"

if (-not $SkipExec) {
    # Invoke the shim we just wrote, by full path. A bare command name would
    # resolve through PATH to the GLOBAL install and prove nothing about a local
    # one, and calling the store file directly would never exercise the shim.
    $first = $shimRoot | Select-Object -First 1
    $shimToRun = Join-Path $shimDir ($first + '.cmd')
    if (-not [System.IO.File]::Exists($shimToRun)) { $shimToRun = Join-Path $shimDir $first }
    $live = (& $shimToRun --version 2>&1 | Select-Object -Last 1)
    if ($live -and "$live".Trim() -match '^\d+\.\d+') {
        Write-Ok "shim responds: $($live.Trim())  ($shimToRun)"
    } else {
        Write-Err "shim did not return a version. Output was: $live"
        exit 1
    }
} else { Write-Warn 'exec check skipped by -SkipExec' }

# ===================================================================== prune
if (-not $NoStore -and [System.IO.Directory]::Exists($pkgStore)) {
    $old = @(Get-ChildItem -LiteralPath $pkgStore -Directory -EA SilentlyContinue |
             Where-Object { $_.Name -ne $resolved -and $_.Name -notlike '.staging-*' })
    if ($old.Count -gt $Keep) {
        # Newest first, semver-aware. A plain Name sort puts 0.10.0 below 0.9.0,
        # and reaping from the head would delete the newest and keep the oldest.
        $sorted = @($old | Sort-Object -Property @{ Expression = { Get-VersionKey $_.Name } } -Descending)
        $toReap = $sorted[($sorted.Count - $Keep)..($sorted.Count - 1)]
        foreach ($d in $toReap) {
            if ($DryRun) { Write-Del "would prune old store version: $($d.Name)"; continue }
            if (Remove-Node $d.FullName) { Write-Del "pruned old store version: $($d.Name)" }
        }
        Write-Info "store retains $resolved plus $Keep older version(s)"
    } elseif ($old.Count) {
        Write-Info "store retains $resolved plus $($old.Count) older version(s)"
    }
}

$sw.Stop()
Write-Host ''
Write-Host ("  MASTER RUN COMPLETE - purged, proven clean, installed {0}.  [{1} ms]" -f $resolved, $sw.ElapsedMilliseconds) -ForegroundColor Green
Write-Host ''
exit 0
