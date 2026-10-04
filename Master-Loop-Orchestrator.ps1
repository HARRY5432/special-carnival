#Requires -Version 5.1
<#
.SYNOPSIS
    MASTER LOOP ORCHESTRATOR - Production-grade, world-class Tor IP rotation +
    package download pipeline with configurable repetition, automatic Tor rotation
    intervals, comprehensive logging, health monitoring, and recovery.
#>

[CmdletBinding()]
param(
    [ValidateRange(1, 10000)]
    [int]$Downloads = 100,

    [ValidateRange(0, 10000)]
    [int]$RotateEveryN = 12,

    [ValidateRange(1, 1000)]
    [int]$IpCheckEveryN = 5,

    [string]$Version = '',
    [string]$Integrity = '',

    [ValidateRange(0, 5000)]
    [int]$DelayBetweenDownloads = 500,

    [ValidateRange(1, 60)]
    [int]$DelayBetweenRotations = 5,

    [ValidateRange(10, 300)]
    [int]$TorIntervalSeconds = 30,

    [string]$LogDir = '',
    [switch]$DryRun,
    [switch]$Quiet,
    [switch]$SkipPreflight,

    [ValidateRange(1, 10)]
    [int]$MaxRetries = 3,

    [ValidateRange(30, 600)]
    [int]$TimeoutSeconds = 120
)

$ErrorActionPreference = 'Continue'

$script:RepoRoot = $PSScriptRoot
$script:LogDir = if ($LogDir) { $LogDir } else { Join-Path $script:RepoRoot "logs" (Get-Date -Format 'yyyy-MM-dd_HHmmss') }
$script:MasterLogFile = Join-Path $script:LogDir 'master.log'
$script:CsvLogFile = Join-Path $script:LogDir 'downloads.csv'
$script:IpLogFile = Join-Path $script:LogDir 'ip-rotations.log'
$script:HealthLogFile = Join-Path $script:LogDir 'health.log'

$script:TorProxy = 'socks5h://127.0.0.1:9050'
$script:Telemetry = @{
    StartTime = Get-Date
    CurrentIp = $null
    TorProcessId = $null
    RotationCount = 0
    SuccessCount = 0
    FailureCount = 0
}

function Set-TorProxyEnvironment {
    $env:TOR_PROXY = $script:TorProxy
    $env:ALL_PROXY = $script:TorProxy
    $env:HTTP_PROXY = $script:TorProxy
    $env:HTTPS_PROXY = $script:TorProxy
}

function Write-Log {
    param([string]$Level, [string]$Message)
    $line = "[$(Get-Date -Format 'o')] [$Level] $Message"
    Add-Content -LiteralPath $script:MasterLogFile -Value $line -Encoding UTF8 -ErrorAction SilentlyContinue
}

function Ensure-LogDirectory {
    if (-not (Test-Path -LiteralPath $script:LogDir)) {
        New-Item -ItemType Directory -Path $script:LogDir -Force | Out-Null
    }
    if (-not (Test-Path -LiteralPath $script:MasterLogFile)) { Set-Content -LiteralPath $script:MasterLogFile -Value '' -Encoding UTF8 }
    if (-not (Test-Path -LiteralPath $script:IpLogFile)) { Set-Content -LiteralPath $script:IpLogFile -Value '' -Encoding UTF8 }
    if (-not (Test-Path -LiteralPath $script:HealthLogFile)) { Set-Content -LiteralPath $script:HealthLogFile -Value '' -Encoding UTF8 }
    if (-not (Test-Path -LiteralPath $script:CsvLogFile)) {
        Set-Content -LiteralPath $script:CsvLogFile -Value 'Timestamp,DownloadNumber,Status,DurationMs,ExitCode,IpStart,IpEnd' -Encoding UTF8
    }
}

function Test-Command {
    param([string]$Name)
    return $null -ne (Get-Command $Name -ErrorAction SilentlyContinue)
}

function Invoke-PreflightChecks {
    $checks = @('git', 'python', 'node', 'npm')
    foreach ($check in $checks) {
        if (-not (Test-Command $check)) {
            Write-Error "Required tool '$check' is missing from PATH. Install it first."
            return $false
        }
    }

    Write-Host "Preflight checks passed." -ForegroundColor Green
    return $true
}

function Start-ManagedTor {
    if ($DryRun) {
        Write-Host "[DRY RUN] Would start Tor at 127.0.0.1:9050" -ForegroundColor Yellow
        return $true
    }

    Set-TorProxyEnvironment

    $modulePath = Join-Path $script:RepoRoot 'TorIPChanger.psm1'
    if (-not (Test-Path $modulePath)) {
        Write-Error "Missing Tor module: $modulePath"
        return $false
    }

    Import-Module $modulePath -Force
    $proc = Start-TorIPChanger -IntervalSeconds $TorIntervalSeconds -NoGui
    if ($proc -and $proc.Id) {
        $script:Telemetry.TorProcessId = $proc.Id
        Start-Sleep -Seconds 3
        $ip = Get-TorIP
        if ($ip) {
            $script:Telemetry.CurrentIp = $ip
            return $true
        }
    }

    return $false
}

function Stop-ManagedTor {
    if ($DryRun) {
        Write-Host "[DRY RUN] Would stop Tor" -ForegroundColor Yellow
        return $true
    }

    try {
        Import-Module (Join-Path $script:RepoRoot 'TorIPChanger.psm1') -Force
        Stop-TorIPChanger
        return $true
    }
    catch {
        return $false
    }
}

function Rotate-TorIp {
    param([int]$RotationNumber)

    if ($DryRun) {
        Write-Host "[DRY RUN] Would rotate Tor IP" -ForegroundColor Yellow
        return $true
    }

    $oldIp = $script:Telemetry.CurrentIp
    $sw = [System.Diagnostics.Stopwatch]::StartNew()

    try {
        Import-Module (Join-Path $script:RepoRoot 'TorIPChanger.psm1') -Force
        Start-Sleep -Seconds $DelayBetweenRotations
        $newIp = Get-TorIP
        $sw.Stop()

        if ($newIp -and $newIp -ne $oldIp) {
            $script:Telemetry.CurrentIp = $newIp
            $script:Telemetry.RotationCount++
            $line = "{0},{1},{2},{3},{4}" -f $RotationNumber, $oldIp, $newIp, $sw.ElapsedMilliseconds, 'SUCCESS'
            Add-Content -LiteralPath $script:IpLogFile -Value $line -Encoding UTF8 -ErrorAction SilentlyContinue
            return $true
        }

        $line = "{0},{1},{2},{3},{4}" -f $RotationNumber, $oldIp, ($newIp ?? 'UNKNOWN'), $sw.ElapsedMilliseconds, 'FAILED'
        Add-Content -LiteralPath $script:IpLogFile -Value $line -Encoding UTF8 -ErrorAction SilentlyContinue
        return $false
    }
    catch {
        $sw.Stop()
        $line = "{0},{1},{2},{3},{4}" -f $RotationNumber, $oldIp, 'ERROR', $sw.ElapsedMilliseconds, 'ERROR'
        Add-Content -LiteralPath $script:IpLogFile -Value $line -Encoding UTF8 -ErrorAction SilentlyContinue
        return $false
    }
}

function Invoke-ManagedDownload {
    param([int]$DownloadNumber)

    $ipStart = $script:Telemetry.CurrentIp
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $masterScript = Join-Path $script:RepoRoot 'codeisotope-master.ps1'

    if (-not (Test-Path $masterScript)) {
        Write-Log 'ERROR' "Missing master script: $masterScript"
        return $false
    }

    $args = @(
        '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $masterScript, '-NoStore', '-Force', '-Quiet'
    )

    if ($Version) { $args += @('-Version', $Version) }
    if ($Integrity) { $args += @('-Integrity', $Integrity) }

    $processInfo = New-Object System.Diagnostics.ProcessStartInfo
    $processInfo.FileName = 'powershell'
    $processInfo.ArgumentList.Clear()
    $processInfo.ArgumentList.Add('-NoProfile')
    $processInfo.ArgumentList.Add('-ExecutionPolicy')
    $processInfo.ArgumentList.Add('Bypass')
    $processInfo.ArgumentList.Add('-File')
    $processInfo.ArgumentList.Add($masterScript)
    $processInfo.ArgumentList.Add('-NoStore')
    $processInfo.ArgumentList.Add('-Force')
    $processInfo.ArgumentList.Add('-Quiet')
    if ($Version) {
        $processInfo.ArgumentList.Add('-Version')
        $processInfo.ArgumentList.Add($Version)
    }
    if ($Integrity) {
        $processInfo.ArgumentList.Add('-Integrity')
        $processInfo.ArgumentList.Add($Integrity)
    }
    $processInfo.UseShellExecute = $false
    $processInfo.RedirectStandardOutput = $true
    $processInfo.RedirectStandardError = $true
    $processInfo.CreateNoWindow = $true
    $processInfo.Environment['TOR_PROXY'] = $script:TorProxy
    $processInfo.Environment['ALL_PROXY'] = $script:TorProxy
    $processInfo.Environment['HTTP_PROXY'] = $script:TorProxy
    $processInfo.Environment['HTTPS_PROXY'] = $script:TorProxy

    try {
        $proc = [System.Diagnostics.Process]::Start($processInfo)
        $exited = $proc.WaitForExit($TimeoutSeconds * 1000)
        $sw.Stop()

        $stdout = $proc.StandardOutput.ReadToEnd()
        $stderr = $proc.StandardError.ReadToEnd()
        $exitCode = if ($exited) { $proc.ExitCode } else { 124 }

        if (-not $exited) {
            try { $proc.Kill() } catch {}
            $script:Telemetry.FailureCount++
            Add-Content -LiteralPath $script:CsvLogFile -Value "$(Get-Date -Format 'o'),$DownloadNumber,'TIMEOUT',$($sw.ElapsedMilliseconds),$exitCode,$ipStart,$($script:Telemetry.CurrentIp)" -Encoding UTF8 -ErrorAction SilentlyContinue
            return $false
        }

        if ($exitCode -eq 0) {
            $script:Telemetry.SuccessCount++
            Add-Content -LiteralPath $script:CsvLogFile -Value "$(Get-Date -Format 'o'),$DownloadNumber,'SUCCESS',$($sw.ElapsedMilliseconds),$exitCode,$ipStart,$($script:Telemetry.CurrentIp)" -Encoding UTF8 -ErrorAction SilentlyContinue
            return $true
        }

        $script:Telemetry.FailureCount++
        Add-Content -LiteralPath $script:CsvLogFile -Value "$(Get-Date -Format 'o'),$DownloadNumber,'FAILED',$($sw.ElapsedMilliseconds),$exitCode,$ipStart,$($script:Telemetry.CurrentIp)" -Encoding UTF8 -ErrorAction SilentlyContinue
        return $false
    }
    catch {
        $sw.Stop()
        $script:Telemetry.FailureCount++
        Write-Log 'ERROR' "Download failed for iteration $DownloadNumber: $($_.Exception.Message)"
        return $false
    }
}

function Invoke-MasterLoop {
    if (-not (Invoke-PreflightChecks)) { return $false }
    Ensure-LogDirectory
    Set-TorProxyEnvironment

    if (-not (Start-ManagedTor)) {
        Write-Log 'ERROR' 'Tor startup failed. The loop cannot continue safely.'
        return $false
    }

    $rotationNumber = 0
    $healthCheckNumber = 0

    for ($i = 1; $i -le $Downloads; $i++) {
        if ($RotateEveryN -gt 0 -and ($i -gt 1) -and (($i - 1) % $RotateEveryN -eq 0)) {
            $rotationNumber++
            Rotate-TorIp -RotationNumber $rotationNumber
            Start-Sleep -Milliseconds $DelayBetweenDownloads
        }

        if (($i -gt 1) -and (($i - 1) % $IpCheckEveryN -eq 0)) {
            $healthCheckNumber++
            try {
                Import-Module (Join-Path $script:RepoRoot 'TorIPChanger.psm1') -Force
                $ip = Get-TorIP
                if ($ip) { $script:Telemetry.CurrentIp = $ip }
            }
            catch {
                Write-Log 'WARN' "Tor health check failed at iteration $i."
            }
        }

        Write-Host "[$i/$Downloads] Running managed install..." -ForegroundColor Cyan
        $success = Invoke-ManagedDownload -DownloadNumber $i
        if (-not $success) {
            for ($retry = 1; $retry -le $MaxRetries; $retry++) {
                Write-Host "Retry $retry/$MaxRetries for download #$i" -ForegroundColor Yellow
                Start-Sleep -Seconds 2
                if (Invoke-ManagedDownload -DownloadNumber $i) {
                    $success = $true
                    break
                }
            }
        }

        if ($i -lt $Downloads) { Start-Sleep -Milliseconds $DelayBetweenDownloads }
    }

    Stop-ManagedTor | Out-Null
    Write-Host "Master loop finished. See logs in: $script:LogDir" -ForegroundColor Green
    return $true
}

Write-Host "Starting Special-Carnival Master Loop Orchestrator..." -ForegroundColor Cyan
$started = Invoke-MasterLoop
if ($started) { exit 0 } else { exit 1 }
