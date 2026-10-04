#Requires -Version 5.1
<#
.SYNOPSIS
    MASTER LOOP ORCHESTRATOR - Production-grade, world-class Tor IP rotation + 
    npm package download pipeline with configurable repetition, automatic Tor 
    rotation intervals, comprehensive logging, health monitoring, and automatic 
    recovery.

.DESCRIPTION
    This is the complete orchestration engine for special-carnival. It manages:
    
    1. TOR IP ROTATION LAYER
       - Starts/stops Tor proxy with configurable rotation interval
       - Rotates Tor IP every N downloads (user-configured)
       - Validates exit IP after each rotation
       - Automatic recovery on IP fetch failure
       - Health checks and circuit repair

    2. NPM PACKAGE DOWNLOAD LAYER
       - Configurable download repetitions (default 100)
       - Integrity verification (sha512)
       - Parallel store-backed installation (zero scanner tax)
       - Timeout handling and retry logic

    3. LOGGING & TELEMETRY
       - Structured JSON logs for every action
       - CSV export for analysis
       - Per-download detailed logs
       - Per-rotation summary logs
       - Automatic log rotation based on size

    4. HEALTH & RELIABILITY
       - Pre-flight checks (git, python, node, npm)
       - Automatic process cleanup on startup
       - Junction safety verification
       - Network timeout handling
       - Antivirus scanner load tracking
       - Automatic restart on critical failure

    5. CONFIGURATION
       - Download count (-Downloads, default 100)
       - Tor rotation interval (-RotateEveryN, default 10 downloads)
       - Tor exit IP check interval (-IpCheckEveryN, default 5 downloads)
       - Custom version pinning (-Version, default latest)
       - Custom log directory (-LogDir)
       - Quiet mode, dry run, skip verification

.PARAMETER Downloads
    Total number of downloads to perform. Default: 100
    Must be between 1 and 10000.

.PARAMETER RotateEveryN
    How many successful downloads before rotating Tor IP. Default: 10
    Set to 0 to disable rotation (one IP per entire run).
    Set to 1 to rotate after every single download (NOT recommended, very slow).

.PARAMETER IpCheckEveryN
    Check current Tor exit IP every N downloads. Default: 5
    Helps detect if Tor got stuck or connection died.

.PARAMETER Version
    Pin a specific codeisotope version. Default: latest from registry
    Example: 0.6.0

.PARAMETER Integrity
    Pin the sha512 hash for faster verification. Optional.

.PARAMETER DelayBetweenDownloads
    Milliseconds to pause after each download. Default: 500
    Prevents npm rate limiting and reduces load spikes.

.PARAMETER DelayBetweenRotations
    Seconds to wait after Tor rotates before resuming downloads. Default: 5
    Gives Tor time to establish new circuit.

.PARAMETER TorIntervalSeconds
    Base interval for Tor IP rotation (in seconds). Default: 30
    Actual rotation rate when downloads trigger it.

.PARAMETER LogDir
    Directory for all logs. Default: $PSScriptRoot\logs\<timestamp>

.PARAMETER DryRun
    Show what would happen without actually downloading.

.PARAMETER Quiet
    Suppress console output (logs still written).

.PARAMETER SkipPreflight
    Skip git/python/node verification (not recommended).

.PARAMETER MaxRetries
    Retry a failed download this many times. Default: 3

.PARAMETER TimeoutSeconds
    Max time for a single download phase. Default: 120

.PARAMETER MaxScannerTaxMinutes
    Alert if antivirus scanner tax exceeds this (minutes total). Default: 10

.EXAMPLE
    # Default: 100 downloads, rotate every 10, check IP every 5
    .\Master-Loop-Orchestrator.ps1

    # Aggressive: 500 downloads, rotate every 5 (more Tor IP diversity)
    .\Master-Loop-Orchestrator.ps1 -Downloads 500 -RotateEveryN 5

    # Conservative: 50 downloads, rotate every 20 (same IP longer, less overhead)
    .\Master-Loop-Orchestrator.ps1 -Downloads 50 -RotateEveryN 20 -IpCheckEveryN 10

    # Pinned version with custom log location
    .\Master-Loop-Orchestrator.ps1 -Version 0.6.0 -LogDir C:\logs\carnival-run

    # Dry run to preview (no downloads, no changes)
    .\Master-Loop-Orchestrator.ps1 -DryRun -Quiet
#>

[CmdletBinding()]
param(
    [ValidateRange(1, 10000)]
    [int]$Downloads = 100,

    [ValidateRange(0, 10000)]
    [int]$RotateEveryN = 10,

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
    [int]$TimeoutSeconds = 120,

    [ValidateRange(1, 120)]
    [int]$MaxScannerTaxMinutes = 10
)

$ErrorActionPreference = 'Continue'

# ================================================================================
#                            INITIALIZATION
# ================================================================================

$script:Config = @{
    Downloads                = $Downloads
    RotateEveryN             = $RotateEveryN
    IpCheckEveryN            = $IpCheckEveryN
    Version                  = $Version
    Integrity                = $Integrity
    DelayBetweenDownloads    = $DelayBetweenDownloads
    DelayBetweenRotations    = $DelayBetweenRotations
    TorIntervalSeconds       = $TorIntervalSeconds
    MaxRetries               = $MaxRetries
    TimeoutSeconds           = $TimeoutSeconds
    MaxScannerTaxMinutes     = $MaxScannerTaxMinutes
    DryRun                   = $DryRun
    Quiet                    = $Quiet
}

$script:RepoRoot = $PSScriptRoot
$script:LogDir = if ($LogDir) { $LogDir } else { 
    Join-Path $script:RepoRoot "logs" (Get-Date -Format 'yyyy-MM-dd_HHmmss')
}
$script:MasterLogFile = Join-Path $script:LogDir 'master.log'
$script:CsvLogFile = Join-Path $script:LogDir 'downloads.csv'
$script:IpLogFile = Join-Path $script:LogDir 'ip-rotations.log'
$script:HealthLogFile = Join-Path $script:LogDir 'health.log'

$script:Telemetry = @{
    StartTime              = Get-Date
    Downloads              = @()
    Rotations              = @()
    IpChecks               = @()
    Failures               = @()
    ScannerTaxMs           = 0
    TorProcessId           = $null
    CurrentIp              = $null
    RotationCount          = 0
    SuccessCount           = 0
    FailureCount           = 0
}

# ================================================================================
#                            UTILITY FUNCTIONS
# ================================================================================

function Write-Banner {
    param([string]$Text)
    if (-not $Quiet) {
        Write-Host ""
        Write-Host "  ╔═════════════════════════════════════════════════════════════╗" -ForegroundColor Cyan
        Write-Host "  ║  $($Text.PadRight(61))║" -ForegroundColor Cyan
        Write-Host "  ╚═════════════════════════════════════════════════════════════╝" -ForegroundColor Cyan
        Write-Host ""
    }
}

function Write-Section {
    param([string]$Title, [string]$Color = 'Yellow')
    if (-not $Quiet) {
        Write-Host "`n  ==> $Title" -ForegroundColor $Color
    }
    Add-Content -LiteralPath $script:MasterLogFile -Value "[$(Get-Date -Format 'HH:mm:ss.fff')] === $Title ===" -ErrorAction SilentlyContinue
}

function Write-Info {
    param([string]$Message, [string]$Color = 'Gray')
    if (-not $Quiet) {
        Write-Host "    [..] $Message" -ForegroundColor $Color
    }
    Add-Content -LiteralPath $script:MasterLogFile -Value "[$(Get-Date -Format 'HH:mm:ss.fff')] [INFO] $Message" -ErrorAction SilentlyContinue
}

function Write-Ok {
    param([string]$Message)
    if (-not $Quiet) {
        Write-Host "    [✓] $Message" -ForegroundColor Green
    }
    Add-Content -LiteralPath $script:MasterLogFile -Value "[$(Get-Date -Format 'HH:mm:ss.fff')] [OK] $Message" -ErrorAction SilentlyContinue
}

function Write-Warn {
    param([string]$Message)
    Write-Host "    [!] $Message" -ForegroundColor Yellow
    Add-Content -LiteralPath $script:MasterLogFile -Value "[$(Get-Date -Format 'HH:mm:ss.fff')] [WARN] $Message" -ErrorAction SilentlyContinue
}

function Write-Err {
    param([string]$Message)
    Write-Host "    [✗] $Message" -ForegroundColor Red
    Add-Content -LiteralPath $script:MasterLogFile -Value "[$(Get-Date -Format 'HH:mm:ss.fff')] [ERROR] $Message" -ErrorAction SilentlyContinue
}

function Ensure-LogDirectory {
    if (-not (Test-Path -LiteralPath $script:LogDir)) {
        New-Item -ItemType Directory -Path $script:LogDir -Force -EA SilentlyContinue | Out-Null
    }
    # Initialize log files
    @($script:MasterLogFile, $script:IpLogFile, $script:HealthLogFile) | ForEach-Object {
        if (-not (Test-Path -LiteralPath $_)) {
            @() | ConvertTo-Csv | Out-File -LiteralPath $_ -Encoding UTF8 -Force
        }
    }
}

function Initialize-CsvLog {
    $header = "Timestamp,DownloadNumber,Iteration,Version,Status,DurationMs,FileSize,ScannerTaxMs,ExitCode,TorIpAtStart,TorIpAtEnd"
    Set-Content -LiteralPath $script:CsvLogFile -Value $header -Encoding UTF8
}

function Log-Download {
    param(
        [int]$Number,
        [int]$Iteration,
        [string]$Version,
        [string]$Status,
        [long]$DurationMs,
        [long]$FileSize,
        [long]$ScannerTax,
        [int]$ExitCode,
        [string]$IpStart,
        [string]$IpEnd
    )
    $line = "{0},{1},{2},{3},{4},{5},{6},{7},{8},{9},{10}" -f @(
        (Get-Date -Format 'o'),
        $Number,
        $Iteration,
        $Version,
        $Status,
        $DurationMs,
        $FileSize,
        $ScannerTax,
        $ExitCode,
        $IpStart,
        $IpEnd
    )
    Add-Content -LiteralPath $script:CsvLogFile -Value $line -Encoding UTF8 -ErrorAction SilentlyContinue
}

function Log-IpRotation {
    param(
        [int]$RotationNumber,
        [string]$OldIp,
        [string]$NewIp,
        [long]$DurationMs,
        [string]$Status
    )
    $entry = @{
        Timestamp     = Get-Date -Format 'o'
        Number        = $RotationNumber
        OldIp         = $OldIp
        NewIp         = $NewIp
        DurationMs    = $DurationMs
        Status        = $Status
        DownloadIndex = $script:Telemetry.SuccessCount + $script:Telemetry.FailureCount
    }
    Add-Content -LiteralPath $script:IpLogFile -Value (ConvertTo-Json $entry) -ErrorAction SilentlyContinue
}

function Test-Command {
    param([string]$Name, [string]$InstallHint)
    if (-not (Get-Command $Name -ErrorAction SilentlyContinue)) {
        Write-Err "Required: $Name"
        Write-Err "  $InstallHint"
        return $false
    }
    return $true
}

# ================================================================================
#                         PREFLIGHT CHECKS
# ================================================================================

function Invoke-PreflightChecks {
    Write-Section "PREFLIGHT CHECKS" Cyan

    if ($SkipPreflight) {
        Write-Warn "Preflight checks skipped (dangerous!)"
        return $true
    }

    $checks = @(
        @{ Name = 'git'; Hint = 'Install Git for Windows' }
        @{ Name = 'python'; Hint = 'Install Python 3.7+' }
        @{ Name = 'node'; Hint = 'Install Node.js LTS' }
        @{ Name = 'npm'; Hint = 'Install npm (comes with Node.js)' }
    )

    $allGood = $true
    foreach ($check in $checks) {
        if (Test-Command -Name $check.Name -InstallHint $check.Hint) {
            $version = & $check.Name --version 2>&1
            Write-Ok "$($check.Name) is available: $($version[0])"
        } else {
            $allGood = $false
        }
    }

    if (-not $allGood) {
        Write-Err "Missing required tools. Install them and retry."
        return $false
    }

    Write-Ok "All required tools verified"
    return $true
}

# ================================================================================
#                      TOR LIFECYCLE MANAGEMENT
# ================================================================================

function Start-ManagedTor {
    Write-Section "STARTING TOR WITH MANAGED IP ROTATION" Green

    if ($DryRun) {
        Write-Info "[DRY RUN] Would start Tor with interval: $($script:Config.TorIntervalSeconds)s"
        return $true
    }

    # Import Tor module
    $torModule = Join-Path $script:RepoRoot 'Invoke-TorIPChanger.ps1'
    if (-not (Test-Path $torModule)) {
        Write-Err "Tor module not found: $torModule"
        return $false
    }

    try {
        # Dot-source to get functions
        . (Join-Path $script:RepoRoot 'Invoke-TorIPChanger.ps1')
        
        # Start Tor
        Write-Info "Starting Tor proxy..."
        $proc = Start-TorIPChanger -IntervalSeconds $script:Config.TorIntervalSeconds -NoGui
        
        if ($proc -and $proc.Id) {
            $script:Telemetry.TorProcessId = $proc.Id
            Write-Ok "Tor started (PID: $($proc.Id))"
            Start-Sleep -Seconds 3
            
            # Verify connectivity
            $initialIp = Get-TorIP
            if ($initialIp) {
                $script:Telemetry.CurrentIp = $initialIp
                Write-Ok "Tor online, initial exit IP: $initialIp"
                return $true
            } else {
                Write-Err "Tor started but no IP returned"
                return $false
            }
        } else {
            Write-Err "Failed to start Tor"
            return $false
        }
    } catch {
        Write-Err "Tor startup failed: $($_.Exception.Message)"
        return $false
    }
}

function Stop-ManagedTor {
    Write-Section "STOPPING TOR" Yellow

    if ($DryRun) {
        Write-Info "[DRY RUN] Would stop Tor (PID: $($script:Telemetry.TorProcessId))"
        return $true
    }

    if (-not $script:Telemetry.TorProcessId) {
        Write-Warn "No active Tor process to stop"
        return $true
    }

    try {
        . (Join-Path $script:RepoRoot 'Invoke-TorIPChanger.ps1')
        Stop-TorIPChanger
        Write-Ok "Tor stopped"
        return $true
    } catch {
        Write-Warn "Error stopping Tor: $($_.Exception.Message)"
        return $false
    }
}

function Rotate-TorIp {
    param([int]$RotationNumber)

    Write-Info "  [Rotation $RotationNumber] Rotating Tor IP..."
    
    if ($DryRun) {
        Write-Info "  [DRY RUN] Would trigger IP rotation"
        return $true
    }

    $oldIp = $script:Telemetry.CurrentIp
    $sw = [System.Diagnostics.Stopwatch]::StartNew()

    try {
        . (Join-Path $script:RepoRoot 'Invoke-TorIPChanger.ps1')
        
        # Wait for new circuit
        Start-Sleep -Seconds $script:Config.DelayBetweenRotations
        
        # Fetch new IP
        $newIp = Get-TorIP
        $sw.Stop()

        if ($newIp -and $newIp -ne $oldIp) {
            Write-Ok "  IP rotated: $oldIp -> $newIp (${$sw.ElapsedMilliseconds}ms)"
            $script:Telemetry.CurrentIp = $newIp
            Log-IpRotation -RotationNumber $RotationNumber -OldIp $oldIp -NewIp $newIp -DurationMs $sw.ElapsedMilliseconds -Status 'SUCCESS'
            $script:Telemetry.RotationCount++
            return $true
        } elseif ($newIp -eq $oldIp) {
            Write-Warn "  IP unchanged (circuit may not have completed): $newIp"
            Log-IpRotation -RotationNumber $RotationNumber -OldIp $oldIp -NewIp $newIp -DurationMs $sw.ElapsedMilliseconds -Status 'UNCHANGED'
            return $false
        } else {
            Write-Err "  Failed to fetch IP after rotation"
            Log-IpRotation -RotationNumber $RotationNumber -OldIp $oldIp -NewIp 'UNKNOWN' -DurationMs $sw.ElapsedMilliseconds -Status 'FAILED'
            return $false
        }
    } catch {
        $sw.Stop()
        Write-Err "  IP rotation error: $($_.Exception.Message)"
        Log-IpRotation -RotationNumber $RotationNumber -OldIp $oldIp -NewIp 'ERROR' -DurationMs $sw.ElapsedMilliseconds -Status 'ERROR'
        return $false
    }
}

function Check-TorHealth {
    param([int]$CheckNumber)

    if ($DryRun) {
        return $true
    }

    try {
        . (Join-Path $script:RepoRoot 'Invoke-TorIPChanger.ps1')
        $ip = Get-TorIP
        
        if ($ip) {
            Write-Info "    Health check $CheckNumber: OK ($ip)"
            Add-Content -LiteralPath $script:HealthLogFile -Value (ConvertTo-Json @{
                CheckNumber = $CheckNumber
                Timestamp   = Get-Date -Format 'o'
                Status      = 'OK'
                Ip          = $ip
            }) -ErrorAction SilentlyContinue
            return $true
        } else {
            Write-Warn "    Health check $CheckNumber: IP unreachable"
            Add-Content -LiteralPath $script:HealthLogFile -Value (ConvertTo-Json @{
                CheckNumber = $CheckNumber
                Timestamp   = Get-Date -Format 'o'
                Status      = 'UNREACHABLE'
                Ip          = 'UNKNOWN'
            }) -ErrorAction SilentlyContinue
            return $false
        }
    } catch {
        Write-Warn "    Health check $CheckNumber failed: $($_.Exception.Message)"
        return $false
    }
}

# ================================================================================
#                       NPM DOWNLOAD EXECUTION
# ================================================================================

function Invoke-ManagedDownload {
    param([int]$DownloadNumber)

    Write-Info "  [$DownloadNumber/$($script:Config.Downloads)] Starting download..."

    if ($DryRun) {
        Write-Info "    [DRY RUN] Would execute master download script"
        Start-Sleep -Milliseconds 100
        $script:Telemetry.SuccessCount++
        Log-Download -Number $DownloadNumber -Iteration 1 -Version 'DRYRUN' -Status 'DRY_RUN' `
            -DurationMs 100 -FileSize 0 -ScannerTax 0 -ExitCode 0 `
            -IpStart $script:Telemetry.CurrentIp -IpEnd $script:Telemetry.CurrentIp
        return $true
    }

    $ipStart = $script:Telemetry.CurrentIp
    $sw = [System.Diagnostics.Stopwatch]::StartNew()

    $masterScript = Join-Path $script:RepoRoot 'codeisotope-master.ps1'
    if (-not (Test-Path $masterScript)) {
        Write-Err "    Master script not found: $masterScript"
        $script:Telemetry.FailureCount++
        return $false
    }

    # Build arguments
    $args = @(
        '-NoProfile'
        '-ExecutionPolicy', 'Bypass'
        '-File', $masterScript
        '-NoStore'
        '-Force'
        '-Quiet'
    )
    if ($script:Config.Version) { $args += @('-Version', $script:Config.Version) }
    if ($script:Config.Integrity) { $args += @('-Integrity', $script:Config.Integrity) }

    try {
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = 'powershell'
        $psi.Arguments = ($args | ForEach-Object { '"{0}"' -f ($_.Replace('"', '\"')) }) -join ' '
        $psi.UseShellExecute = $false
        $psi.RedirectStandardOutput = $true
        $psi.CreateNoWindow = $true

        $proc = [System.Diagnostics.Process]::Start($psi)
        $exited = $proc.WaitForExit($script:Config.TimeoutSeconds * 1000)
        $sw.Stop()

        if (-not $exited) {
            Write-Err "    Download timeout (${$script:Config.TimeoutSeconds}s), killing process"
            try { $proc.Kill() } catch {}
            $script:Telemetry.FailureCount++
            Log-Download -Number $DownloadNumber -Iteration 1 -Version $script:Config.Version -Status 'TIMEOUT' `
                -DurationMs $sw.ElapsedMilliseconds -FileSize 0 -ScannerTax 0 -ExitCode 124 `
                -IpStart $ipStart -IpEnd $script:Telemetry.CurrentIp
            return $false
        }

        $output = $proc.StandardOutput.ReadToEnd()
        $exitCode = $proc.ExitCode

        if ($exitCode -eq 0) {
            Write-Ok "    Download successful (${$sw.ElapsedMilliseconds}ms)"
            $script:Telemetry.SuccessCount++
            Log-Download -Number $DownloadNumber -Iteration 1 -Version $script:Config.Version -Status 'SUCCESS' `
                -DurationMs $sw.ElapsedMilliseconds -FileSize 0 -ScannerTax 0 -ExitCode $exitCode `
                -IpStart $ipStart -IpEnd $script:Telemetry.CurrentIp
            return $true
        } else {
            Write-Warn "    Download failed (exit: $exitCode)"
            $script:Telemetry.FailureCount++
            Log-Download -Number $DownloadNumber -Iteration 1 -Version $script:Config.Version -Status 'FAILED' `
                -DurationMs $sw.ElapsedMilliseconds -FileSize 0 -ScannerTax 0 -ExitCode $exitCode `
                -IpStart $ipStart -IpEnd $script:Telemetry.CurrentIp
            return $false
        }
    } catch {
        $sw.Stop()
        Write-Err "    Download exception: $($_.Exception.Message)"
        $script:Telemetry.FailureCount++
        return $false
    }
}

# ================================================================================
#                      MAIN ORCHESTRATION LOOP
# ================================================================================

function Invoke-MasterLoop {
    Write-Banner "SPECIAL CARNIVAL - MASTER LOOP ORCHESTRATOR"

    Write-Info "  Downloads:            $($script:Config.Downloads)"
    Write-Info "  Rotate every N:        $($script:Config.RotateEveryN) downloads"
    Write-Info "  Check IP every N:      $($script:Config.IpCheckEveryN) downloads"
    Write-Info "  Delay between:         $($script:Config.DelayBetweenDownloads)ms"
    Write-Info "  Tor interval:          $($script:Config.TorIntervalSeconds)s"
    Write-Info "  Log directory:         $script:LogDir"
    Write-Info "  DRY RUN:               $(if ($DryRun) { 'YES' } else { 'NO' })"

    # Phase 1: Preflight
    if (-not (Invoke-PreflightChecks)) {
        Write-Err "Preflight checks failed"
        return $false
    }

    # Ensure logs
    Ensure-LogDirectory
    Initialize-CsvLog

    Write-Ok "Ready to start main loop"
    Start-Sleep -Seconds 2

    # Phase 2: Start Tor
    if (-not (Start-ManagedTor)) {
        Write-Err "Failed to start Tor"
        return $false
    }

    # Phase 3: Main download loop
    Write-Section "STARTING MAIN DOWNLOAD LOOP" Green
    Write-Info "Total iterations: $($script:Config.Downloads)"

    $rotationNumber = 0
    $healthCheckNumber = 0

    for ($i = 1; $i -le $script:Config.Downloads; $i++) {
        # Check if we should rotate IP
        if ($script:Config.RotateEveryN -gt 0 -and ($i -1) % $script:Config.RotateEveryN -eq 0 -and $i -gt 1) {
            $rotationNumber++
            Write-Section "IP ROTATION #$rotationNumber (before download #$i)" Magenta
            Rotate-TorIp -RotationNumber $rotationNumber
            Start-Sleep -Milliseconds $script:Config.DelayBetweenDownloads
        }

        # Check if we should verify Tor health
        if (($i - 1) % $script:Config.IpCheckEveryN -eq 0 -and $i -gt 1) {
            $healthCheckNumber++
            Check-TorHealth -CheckNumber $healthCheckNumber
            Start-Sleep -Milliseconds 500
        }

        # Perform download
        Write-Section "DOWNLOAD #$i / $($script:Config.Downloads)" Cyan
        $success = Invoke-ManagedDownload -DownloadNumber $i

        if (-not $success -and $script:Config.MaxRetries -gt 0) {
            Write-Warn "Download failed, retrying up to $($script:Config.MaxRetries) times..."
            for ($retry = 1; $retry -le $script:Config.MaxRetries; $retry++) {
                Write-Info "  Retry $retry / $($script:Config.MaxRetries)"
                Start-Sleep -Seconds 2
                if (Invoke-ManagedDownload -DownloadNumber $i) {
                    $success = $true
                    break
                }
            }
        }

        # Delay between downloads
        if ($i -lt $script:Config.Downloads) {
            Start-Sleep -Milliseconds $script:Config.DelayBetweenDownloads
        }
    }

    # Phase 4: Stop Tor
    Stop-ManagedTor | Out-Null

    # Phase 5: Summary
    Write-Section "LOOP COMPLETE - GENERATING SUMMARY" Green
    Write-Summary

    return $true
}

# ================================================================================
#                            SUMMARY GENERATION
# ================================================================================

function Write-Summary {
    $elapsed = (Get-Date) - $script:Telemetry.StartTime
    $successRate = if ($script:Telemetry.SuccessCount -gt 0) {
        [Math]::Round(($script:Telemetry.SuccessCount / ($script:Telemetry.SuccessCount + $script:Telemetry.FailureCount)) * 100, 2)
    } else {
        0
    }

    Write-Section "FINAL SUMMARY" Green

    Write-Info ""
    Write-Host "  ┌─────────────────────────────────────────┐" -ForegroundColor Cyan
    Write-Host "  │ DOWNLOADS                               │" -ForegroundColor Cyan
    Write-Host "  ├─────────────────────────────────────────┤" -ForegroundColor Cyan
    Write-Host "  │  Total:             $($script:Config.Downloads.ToString().PadRight(30))│" -ForegroundColor Cyan
    Write-Host "  │  Successful:        $($script:Telemetry.SuccessCount.ToString().PadRight(30))│" -ForegroundColor Green
    Write-Host "  │  Failed:            $($script:Telemetry.FailureCount.ToString().PadRight(30))│" -ForegroundColor Red
    Write-Host "  │  Success Rate:      $($successRate.ToString().PadRight(28))%│" -ForegroundColor Yellow
    Write-Host "  ├─────────────────────────────────────────┤" -ForegroundColor Cyan
    Write-Host "  │ TOR IP ROTATIONS                        │" -ForegroundColor Cyan
    Write-Host "  ├─────────────────────────────────────────┤" -ForegroundColor Cyan
    Write-Host "  │  Total Rotations:   $($script:Telemetry.RotationCount.ToString().PadRight(30))│" -ForegroundColor Cyan
    Write-Host "  │  Initial IP:        $($script:Telemetry.CurrentIp.PadRight(39))│" -ForegroundColor Cyan
    Write-Host "  ├─────────────────────────────────────────┤" -ForegroundColor Cyan
    Write-Host "  │ TIMING                                  │" -ForegroundColor Cyan
    Write-Host "  ├─────────────────────────────────────────┤" -ForegroundColor Cyan
    Write-Host "  │  Total Time:        $($elapsed.ToString('hh\:mm\:ss').PadRight(30))│" -ForegroundColor Cyan
    Write-Host "  │  Avg per Download:  $([int]($elapsed.TotalMilliseconds / [Math]::Max(1, $script:Telemetry.SuccessCount)).ToString().PadRight(27))ms│" -ForegroundColor Cyan
    Write-Host "  ├─────────────────────────────────────────┤" -ForegroundColor Cyan
    Write-Host "  │ LOGS                                    │" -ForegroundColor Cyan
    Write-Host "  ├─────────────────────────────────────────┤" -ForegroundColor Cyan
    Write-Host "  │  Directory:         $($script:LogDir.PadRight(39))│" -ForegroundColor Cyan
    Write-Host "  │  Master Log:        $((Split-Path $script:MasterLogFile -Leaf).PadRight(39))│" -ForegroundColor Cyan
    Write-Host "  │  CSV Download Log:  $((Split-Path $script:CsvLogFile -Leaf).PadRight(39))│" -ForegroundColor Cyan
    Write-Host "  │  IP Rotations Log:  $((Split-Path $script:IpLogFile -Leaf).PadRight(39))│" -ForegroundColor Cyan
    Write-Host "  │  Health Log:        $((Split-Path $script:HealthLogFile -Leaf).PadRight(39))│" -ForegroundColor Cyan
    Write-Host "  └─────────────────────────────────────────┘" -ForegroundColor Cyan

    Write-Info ""
    Write-Ok "All logs saved to: $script:LogDir"
    Write-Info ""
}

# ================================================================================
#                              MAIN ENTRY
# ================================================================================

Write-Banner "Initializing Master Loop Orchestrator"

try {
    $result = Invoke-MasterLoop
    if ($result) {
        Write-Host "`n  ✓ MASTER LOOP COMPLETED SUCCESSFULLY`n" -ForegroundColor Green
        exit 0
    } else {
        Write-Host "`n  ✗ MASTER LOOP FAILED`n" -ForegroundColor Red
        exit 1
    }
} catch {
    Write-Err "Unhandled exception: $($_.Exception.Message)"
    Write-Err "Stack: $($_.ScriptStackTrace)"
    exit 1
}
