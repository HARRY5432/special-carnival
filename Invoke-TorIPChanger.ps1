param(
    [Parameter(Mandatory=$false)]
    [int]$IntervalSeconds = 30,
    [Parameter(Mandatory=$false)]
    [string]$TorIPChangerPath = "./tor-ip-changer"
)

<#
.SYNOPSIS
PowerShell wrapper to integrate tor-ip-changer Python tool
.DESCRIPTION
Manages Tor IP rotation with configurable intervals
#>

# Validate Python is installed
try {
    $pythonVersion = python --version 2>&1
    Write-Host "✓ Python found: $pythonVersion"
} catch {
    Write-Error "Python is required but not installed. Install from https://python.org/"
    exit 1
}

# Validate Tor IP Changer repository exists
if (-not (Test-Path $TorIPChangerPath)) {
    Write-Error "tor-ip-changer directory not found at: $TorIPChangerPath"
    exit 1
}

$torScript = Join-Path $TorIPChangerPath "torip.py"
if (-not (Test-Path $torScript)) {
    Write-Error "torip.py not found at: $torScript"
    exit 1
}

# Install dependencies
Write-Host "Installing Python dependencies..." -ForegroundColor Cyan
Push-Location $TorIPChangerPath
try {
    pip install -q requests stem 2>&1 | Out-Null
    if ($LASTEXITCODE -eq 0) {
        Write-Host "✓ Dependencies installed successfully" -ForegroundColor Green
    } else {
        Write-Warning "Dependency installation completed with warnings"
    }
} catch {
    Write-Error "Failed to install dependencies: $_"
    exit 1
} finally {
    Pop-Location
}

# Validate Tor is running
Write-Host "Checking Tor daemon..." -ForegroundColor Cyan
$torCheck = @"
import socket
try:
    sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    result = sock.connect_ex(('127.0.0.1', 9050))
    sock.close()
    exit(0 if result == 0 else 1)
except:
    exit(1)
"@

$torRunning = python -c $torCheck
if ($LASTEXITCODE -ne 0) {
    Write-Warning "Tor does not appear to be running on localhost:9050"
    Write-Host "Ensure Tor is started: sudo service tor start (Linux) or Tor Browser (Windows/Mac)"
}

# Execute Tor IP changer with optimal tuning
Write-Host "Starting Tor IP rotation (interval: ${IntervalSeconds}s)..." -ForegroundColor Green
Write-Host "Press Ctrl+C to stop" -ForegroundColor Yellow

$pythonCmd = @(
    $torScript
    "--interval=$IntervalSeconds"
)

try {
    & python $pythonCmd
} catch {
    Write-Error "Error executing tor-ip-changer: $_"
    exit 1
}
