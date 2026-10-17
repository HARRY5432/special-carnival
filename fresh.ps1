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

.PARAMETER UseTor
    Start the cloned tor-ip-changer runtime, route every CodeIsotope download
    through its SOCKS5 proxy, and request a new Tor identity between runs. This
    is opt-in; without this switch the existing direct-download behavior is
    unchanged.

.PARAMETER UseZenRows
    Use the ZenRows Fetch API for registry metadata and tarball downloads.
    Requires ZENROWS_API_KEY in the environment and is mutually exclusive with
    -UseTor. This is opt-in and leaves the existing direct and Tor paths alone.

.PARAMETER ZenRowsPremiumProxy
    With -UseZenRows, route requests through ZenRows' residential Premium Proxy
    pool. Each successful request costs 10 credits instead of the standard one.

.PARAMETER PinResolution
    Resolve latest/version and integrity once before the loop, then reuse that
    verified resolution for every run. This removes one metadata request per
    iteration while still downloading and verifying a fresh tarball every time.

.PARAMETER TorRoot
    Path to the cloned tor-ip-changer repository. Default is a sibling folder
    named tor-ip-changer next to this script.

.PARAMETER TorExecutable
    Optional path to ipchanger.exe. If omitted, the Windows 1.3.0 executable
    is extracted from TorRoot\dist\1.3.0\ipchanger.rar on first use.

.PARAMETER TorProxyHost / TorProxyPort
    SOCKS5 endpoint exposed by tor-ip-changer. Defaults to 127.0.0.1:9050.

.PARAMETER TorApiHost / TorApiPort
    Local API endpoint used to start Tor and rotate identities. Defaults to
    127.0.0.1:14999.

.PARAMETER TorStartupTimeoutSeconds
    Maximum time to wait for the API and SOCKS5 listener to open. Default 120.

.PARAMETER TorIdentityTimeoutSeconds
    Maximum time to wait for one requested identity rotation. Default 120.

.PARAMETER TorDelayIncludesIdentity
    With -UseTor, count identity-rotation time toward DelaySeconds. The next
    download still waits for rotation to finish, but the configured delay is
    measured from the end of the previous download instead of after rotation.
    This is opt-in; the default keeps the existing Tor pacing.

.EXAMPLE
    .\fresh.ps1
    .\fresh.ps1 -Times 50
    .\fresh.ps1 -Times 10 -Version 0.6.0 -DelaySeconds 5
    .\fresh.ps1 -Times 50 -UseTor
    .\fresh.ps1 -Times 50 -UseTor -PinResolution -TorDelayIncludesIdentity
    .\fresh.ps1 -Times 50 -UseZenRows -ZenRowsPremiumProxy -PinResolution
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

    [switch]$Quiet,

    [switch]$UseTor,

    [Alias('ZenRows')]
    [switch]$UseZenRows,

    [switch]$ZenRowsPremiumProxy,

    [switch]$PinResolution,

    [string]$TorRoot = '',

    [string]$TorExecutable = '',

    [string]$TorProxyHost = '127.0.0.1',

    [ValidateRange(1, 65535)]
    [int]$TorProxyPort = 9050,

    [string]$TorApiHost = '127.0.0.1',

    [ValidateRange(1, 65535)]
    [int]$TorApiPort = 14999,

    [ValidateRange(10, 900)]
    [int]$TorStartupTimeoutSeconds = 120,

    [ValidateRange(10, 900)]
    [int]$TorIdentityTimeoutSeconds = 120,

    [switch]$TorDelayIncludesIdentity
)

$ErrorActionPreference = 'Stop'
if (-not $Log) { $Log = Join-Path $PSScriptRoot 'fresh.log' }
$master = Join-Path $PSScriptRoot 'codeisotope-master.ps1'

if ($UseTor -and $UseZenRows) {
    Write-Host 'ERROR: -UseTor and -UseZenRows are alternative transports; choose one.' -ForegroundColor Red
    exit 1
}
if ($ZenRowsPremiumProxy -and -not $UseZenRows) {
    Write-Host 'ERROR: -ZenRowsPremiumProxy requires -UseZenRows.' -ForegroundColor Red
    exit 1
}
if ($UseZenRows -and [string]::IsNullOrWhiteSpace([string]$env:ZENROWS_API_KEY)) {
    Write-Host 'ERROR: -UseZenRows requires the ZENROWS_API_KEY environment variable.' -ForegroundColor Red
    exit 1
}
if ($TorDelayIncludesIdentity -and -not $UseTor) {
    Write-Host 'ERROR: -TorDelayIncludesIdentity requires -UseTor.' -ForegroundColor Red
    exit 1
}

if (-not (Test-Path -LiteralPath $master)) {
    Write-Host "ERROR: master script not found at $master" -ForegroundColor Red
    exit 1
}

$logDir = Split-Path $Log -Parent
if ($logDir -and -not (Test-Path -LiteralPath $logDir)) {
    New-Item -ItemType Directory -Path $logDir -Force | Out-Null
}

$torSession = $null
if ($UseTor) {
    $torHelper = Join-Path $PSScriptRoot 'tor-proxy.ps1'
    if (-not (Test-Path -LiteralPath $torHelper)) {
        Write-Host "ERROR: Tor integration helper not found at $torHelper" -ForegroundColor Red
        exit 1
    }
    if (-not $TorRoot) { $TorRoot = Join-Path $PSScriptRoot 'tor-ip-changer' }
    if (-not (Test-Path -LiteralPath $TorRoot -PathType Container)) {
        Write-Host "ERROR: Tor repository folder not found at $TorRoot" -ForegroundColor Red
        exit 1
    }
    . $torHelper
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
    if ($UseTor) {
        Write-Host "  network: Tor SOCKS5 ${TorProxyHost}:$TorProxyPort (identity API ${TorApiHost}:$TorApiPort)"
        Write-Host "  tor    : $TorRoot"
        if ($TorDelayIncludesIdentity) {
            Write-Host "  pacing : identity rotation is included in the ${DelaySeconds}s inter-run delay"
        }
    } elseif ($UseZenRows) {
        Write-Host ("  network: ZenRows Fetch API{0}" -f $(if ($ZenRowsPremiumProxy) { ' + residential Premium Proxy' } else { '' }))
    }
    if ($PinResolution) {
        Write-Host '  resolve: package version and integrity resolved once, tarball downloaded every run'
    }
    Write-Host "  log    : $Log"
    Write-Host ''
}

$totalSw = [System.Diagnostics.Stopwatch]::StartNew()
$successCount = 0
$failCount = 0
$pinnedVersion = $Version
$pinnedIntegrity = ''

try {
    if ($UseTor) {
        $torSession = Start-CodeIsotopeTorProxy -TorRoot $TorRoot -ExecutablePath $TorExecutable `
            -ApiHost $TorApiHost -ApiPort $TorApiPort -ProxyHost $TorProxyHost -ProxyPort $TorProxyPort `
            -StartupTimeoutSeconds $TorStartupTimeoutSeconds -IdentityTimeoutSeconds $TorIdentityTimeoutSeconds
    }

    if ($PinResolution) {
        $resolveArgs = @(
            '-NoProfile'
            '-ExecutionPolicy', 'Bypass'
            '-File', $master
            '-ResolveOnly'
            '-Force'
        )
        if ($Version) { $resolveArgs += @('-Version', $Version) }
        if ($UseTor) { $resolveArgs += @('-SocksProxy', "${TorProxyHost}:$TorProxyPort") }
        if ($UseZenRows) {
            $resolveArgs += '-ZenRows'
            if ($ZenRowsPremiumProxy) { $resolveArgs += '-ZenRowsPremiumProxy' }
        }
        $resolveOutput = @(& powershell @resolveArgs 2>&1 | ForEach-Object { "$($_)" })
        $resolveCode = $LASTEXITCODE
        $resolveText = $resolveOutput -join "`n"
        if ($resolveCode -ne 0) {
            # Surface the child diagnostic, but never echo a request URI or an
            # API key if a transport reports one unexpectedly.
            $safeDiagnostic = @($resolveOutput |
                Where-Object { $_ -notmatch '(?i)apikey|ZENROWS_API_KEY|api\.zenrows\.com/v1/\?' } |
                Select-Object -Last 4) -join ' '
            if ($safeDiagnostic) {
                throw "Could not resolve the package before the loop (exit $resolveCode): $safeDiagnostic"
            }
            throw "Could not resolve the package before the loop (exit $resolveCode)."
        }
        if ($resolveText -notmatch 'RESOLVED_VERSION=([^\s]+)') {
            throw 'The resolver returned no package version.'
        }
        $pinnedVersion = $Matches[1]
        if ($resolveText -notmatch 'RESOLVED_INTEGRITY=(sha512-[^\s]+)') {
            throw 'The resolver returned no sha512 integrity value.'
        }
        $pinnedIntegrity = $Matches[1]
        if (-not $Quiet) { Write-Host "  resolved: $pinnedVersion ($pinnedIntegrity)" -ForegroundColor DarkGray }
    }

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
    if ($PinResolution) {
        $psiArgs += @('-Version', $pinnedVersion, '-Integrity', $pinnedIntegrity)
    } elseif ($Version) {
        $psiArgs += @('-Version', $Version)
    }
    if ($SkipExec) { $psiArgs += '-SkipExec' }
    if ($Quiet) { $psiArgs += '-Quiet' }
    if ($UseTor) { $psiArgs += @('-SocksProxy', "${TorProxyHost}:$TorProxyPort") }
    if ($UseZenRows) {
        $psiArgs += '-ZenRows'
        if ($ZenRowsPremiumProxy) { $psiArgs += '-ZenRowsPremiumProxy' }
        # A fresh session per loop iteration keeps the metadata and tarball for
        # one install consistent while allowing the next install to use a new
        # residential IP when Premium Proxy is enabled.
        $zenRowsSessionId = [math]::Abs([int](([DateTime]::UtcNow.Ticks + $i) % 2147483647))
        if ($zenRowsSessionId -eq 0) { $zenRowsSessionId = 1 }
        $psiArgs += @('-ZenRowsSessionId', [string]$zenRowsSessionId)
    }

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
        # Kill the process tree as well as powershell.exe. The master can have
        # curl.exe underneath it; leaving that child alive can keep a network
        # request and its temporary output file open after a timeout.
        if ($UseTor) {
            try {
                & taskkill.exe /PID $pr.Id /T /F 1>$null 2>$null
            } catch {}
        }
        try { $pr.Kill() } catch {}
        $null = $pr.WaitForExit(5000)
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

    # Release the native process handle on every iteration. This matters for
    # long Tor loops and does not alter the direct or Tor download contract.
    $pr.Dispose()
    $pr = $null

        if ($i -lt $Times) {
            if ($UseTor) {
                $identitySw = [System.Diagnostics.Stopwatch]::StartNew()
                $null = Request-CodeIsotopeTorIdentity -Session $torSession -TimeoutSeconds $TorIdentityTimeoutSeconds
                $identitySw.Stop()
                if ($TorDelayIncludesIdentity) {
                    $remainingDelayMs = ($DelaySeconds * 1000) - $identitySw.ElapsedMilliseconds
                    if ($remainingDelayMs -gt 0) {
                        Start-Sleep -Milliseconds ([int]$remainingDelayMs)
                    }
                } else {
                    Start-Sleep -Seconds $DelaySeconds
                }
            } else {
                Start-Sleep -Seconds $DelaySeconds
            }
        }
    }
}
finally {
    if ($torSession) { $null = Stop-CodeIsotopeTorProxy -Session $torSession }
}

$totalSw.Stop()

if (-not $Quiet) {
    Write-Host ''
    Write-Host "  COMPLETE  $successCount succeeded, $failCount failed, $($totalSw.ElapsedMilliseconds)ms total" -ForegroundColor $(if ($failCount -eq 0) { 'Green' } else { 'Yellow' })
    Write-Host "  log saved: $Log"
    Write-Host ''
}

exit $(if ($failCount -gt 0) { 1 } else { 0 })
