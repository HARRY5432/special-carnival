#Requires -Version 5.1
<#
.SYNOPSIS
    Fresh-download wrapper for codeisotope-master.ps1. Every run downloads the
    package file again from the npm registry, so each execution counts as one
    download. No store reuse, no version cache.

.DESCRIPTION
    Calls codeisotope-master.ps1 with -NoStore -Force internally. Adds a loop
    (-Times N) with polite pacing and a per-run log file.

.PARAMETER Times
    How many fresh downloads to perform. Default 1. Each iteration deletes the
    previous install, re-downloads, re-installs, and verifies.

.PARAMETER Version
    Pin a specific version (e.g. "0.6.0"). Without this flag every iteration
    resolves "latest" live from the registry, so a new release mid-loop is
    picked up automatically.

.PARAMETER Log
    Path to the log file. Default: F:\stancore\codeisotope\fresh.log. Each run
    appends one line: timestamp, version resolved, bytes downloaded, exit code,
    elapsed ms.

.PARAMETER DelaySeconds
    Pause between iterations to avoid triggering npm rate limits. Default 3.
    Minimum 1.

.PARAMETER RunTimeoutSeconds
    Maximum wall time per iteration (default 150). A run that exceeds it is
    killed, logged with exit=124, and the loop continues with the next run.
    This is what stops one stalled download from freezing the whole batch.

.PARAMETER Scope
    Global (default), Local, or Both. Passed through to the master script.

.PARAMETER SkipExec
    Skip the final binary-launch verification. Faster, but you won't know if
    the shim is broken until you try it yourself.

.PARAMETER Quiet
    Suppress all console output. The log file still records everything.

.EXAMPLE
    .\fresh.ps1
    .\fresh.ps1 -Times 50
    .\fresh.ps1 -Times 10 -Version 0.6.0 -DelaySeconds 5
    .\fresh.ps1 -Log C:\tmp\downloads.log -Quiet
#>

[CmdletBinding()]
param(
    [ValidateRange(1, 10000)]
    [int]$Times = 1,

    [string]$Version = '',

    [string]$Log = '',

    [ValidateRange(1, 300)]
    [int]$DelaySeconds = 3,

    [ValidateRange(30, 900)]
    [int]$RunTimeoutSeconds = 150,

    [ValidateSet('Global', 'Local', 'Both')]
    [string]$Scope = 'Global',

    [switch]$SkipExec,

    [switch]$Quiet
)

$ErrorActionPreference = 'Stop'
if (-not $Log) { $Log = Join-Path $PSScriptRoot 'fresh.log' }
$master = Join-Path $PSScriptRoot 'codeisotope-master.ps1'

if (-not (Test-Path -LiteralPath $master)) {
    Write-Host "ERROR: master script not found at $master" -ForegroundColor Red
    exit 1
}

$logDir = Split-Path $Log -Parent
if ($logDir -and -not (Test-Path -LiteralPath $logDir)) {
    New-Item -ItemType Directory -Path $logDir -Force | Out-Null
}

function Write-LogLine {
    param([string]$RunNum, [string]$Ver, [long]$Bytes, [int]$ExitCode, [long]$Ms)
    $ts = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
    $line = "{0}`t{1}`t{2}`tver={3}`tbytes={4}`texit={5}`tms={6}" -f $ts, $RunNum, $Times, $Ver, $Bytes, $ExitCode, $Ms
    Add-Content -LiteralPath $Log -Value $line -Encoding UTF8
}

if (-not $Quiet) {
    Write-Host ''
    Write-Host "  CODEISOTOPE FRESH DOWNLOAD" -ForegroundColor White
    Write-Host "  ==========================" -ForegroundColor DarkGray
    Write-Host "  runs   : $Times"
    Write-Host "  version: $(if ($Version) { $Version } else { 'latest (resolved each time)' })"
    Write-Host "  scope  : $Scope"
    Write-Host "  delay  : ${DelaySeconds}s between runs"
    Write-Host "  timeout: ${RunTimeoutSeconds}s per run (timed-out runs are killed, logged, skipped)"
    Write-Host "  log    : $Log"
    Write-Host ''
}

$totalSw = [System.Diagnostics.Stopwatch]::StartNew()
$successCount = 0
$failCount = 0

for ($i = 1; $i -le $Times; $i++) {
    $runSw = [System.Diagnostics.Stopwatch]::StartNew()

    if (-not $Quiet) {
        $label = "  [$i/$Times]"
        Write-Host "$label downloading fresh..." -ForegroundColor Cyan -NoNewline
    }

    # $psiArgs, not $args: $args is a PowerShell automatic variable.
    $psiArgs = @(
        '-NoProfile'
        '-ExecutionPolicy', 'Bypass'
        '-File', $master
        '-NoStore'
        '-Force'
        '-Scope', $Scope
    )
    if ($Version) { $psiArgs += @('-Version', $Version) }
    if ($SkipExec) { $psiArgs += '-SkipExec' }
    if ($Quiet) { $psiArgs += '-Quiet' }

    # Raw .NET Process, not Start-Process: Start-Process -Redirect* never
    # populates .ExitCode on PowerShell 5.1 (it stays empty even after
    # WaitForExit), so success/failure could not be detected. The .NET API
    # reports it correctly.
    $argString = ($psiArgs | ForEach-Object { '"{0}"' -f ($_.Replace('"', '\"')) }) -join ' '
    # Only stdout is redirected. Redirecting stderr too and then ReadToEnd-ing
    # stdout first is a textbook deadlock: the child blocks writing to a full
    # stderr buffer while the parent blocks reading stdout, and neither moves.
    # An unredirected stderr simply inherits this console and cannot fill up.
    $psiInfo = New-Object System.Diagnostics.ProcessStartInfo
    $psiInfo.FileName = 'powershell'
    $psiInfo.Arguments = $argString
    $psiInfo.UseShellExecute = $false
    $psiInfo.CreateNoWindow = $true
    $psiInfo.RedirectStandardOutput = $true
    $psiInfo.RedirectStandardError = $false
    $pr = [System.Diagnostics.Process]::Start($psiInfo)
    # Bounded wait. An unbounded wait here is how a stalled child (e.g. a
    # throttled registry connection inside the master run) froze the whole loop
    # with no output. On timeout the child is killed, the run is logged as a
    # timeout, and the loop continues — the next iteration's purge-first design
    # repairs any half-installed state.
    # Reading order is deliberate and deadlock-free: only stdout is redirected
    # (stderr inherits this console), and the master writes ~2KB, far below the
    # 64KB pipe buffer, so the child can never block on a full pipe while we
    # wait. ReadToEnd runs AFTER exit/kill, when the stream is already closed,
    # so it returns immediately with everything. No background reader threads:
    # PowerShell scriptblocks marshalled to pool threads fault without a
    # runspace, which silently swallowed all output in an earlier revision.
    $timedOut = $false
    $exited = $pr.WaitForExit($RunTimeoutSeconds * 1000)
    if (-not $exited) {
        $timedOut = $true
        try { $pr.Kill() } catch {}
        $pr.WaitForExit(5000)
        $exitCode = 124
    } else {
        $exitCode = $pr.ExitCode
    }
    $stdout = $pr.StandardOutput.ReadToEnd()
    $stderr = ''
    $runSw.Stop()

    $resolvedVer = 'unknown'
    if ($stdout -match 'installed\s+(\d+\.\d+\.\d+[^\s]*)') {
        $resolvedVer = $Matches[1].TrimEnd('.')
    } elseif ($stdout -match 'resolved.*?:\s*(\d+\.\d+\.\d+[^\s]*)') {
        $resolvedVer = $Matches[1].TrimEnd('.')
    } elseif ($Version) {
        $resolvedVer = $Version
    }

    $bytes = 0
    if ($stdout -match 'downloaded\s+([\d,]+)\s+bytes') {
        $bytes = [long]($Matches[1] -replace ',', '')
    }

    if ($exitCode -eq 0) { $successCount++ } else { $failCount++ }

    Write-LogLine -RunNum "$i" -Ver $resolvedVer -Bytes $bytes -ExitCode $exitCode -Ms $runSw.ElapsedMilliseconds

    if (-not $Quiet) {
        if ($exitCode -eq 0) {
            Write-Host " done  ver=$resolvedVer  $($runSw.ElapsedMilliseconds)ms" -ForegroundColor Green
        } elseif ($timedOut) {
            Write-Host " TIMEOUT after ${RunTimeoutSeconds}s (child killed, continuing)" -ForegroundColor Yellow
        } else {
            Write-Host " FAILED  exit=$exitCode  $($runSw.ElapsedMilliseconds)ms" -ForegroundColor Red
            if ($stderr) {
                $errLines = ($stderr -split "`n" | Where-Object { $_.Trim() } | Select-Object -First 3)
                foreach ($el in $errLines) { Write-Host "         $el" -ForegroundColor DarkRed }
            }
        }
    }

    if ($i -lt $Times) {
        Start-Sleep -Seconds $DelaySeconds
    }
}

$totalSw.Stop()

if (-not $Quiet) {
    Write-Host ''
    Write-Host "  COMPLETE  $successCount succeeded, $failCount failed, $($totalSw.ElapsedMilliseconds)ms total" -ForegroundColor $(if ($failCount -eq 0) { 'Green' } else { 'Yellow' })
    Write-Host "  log saved: $Log"
    Write-Host ''
}

exit $(if ($failCount -gt 0) { 1 } else { 0 })
