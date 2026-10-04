Set-StrictMode -Version Latest

$script:TorRepoInstallRoot = Join-Path $PSScriptRoot "tools"
$script:TorRepoPath = Join-Path $script:TorRepoInstallRoot "tor-ip-changer"

function Ensure-Command {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name,
        [string]$InstallHint
    )

    if (-not (Get-Command $Name -ErrorAction SilentlyContinue)) {
        throw "Required command '$Name' was not found. $InstallHint"
    }
}

function Ensure-TorIPChanger {
    [CmdletBinding()]
    param(
        [string]$InstallPath = $script:TorRepoPath
    )

    Ensure-Command -Name git -InstallHint "Install Git and try again."

    $pythonName = if ($IsWindows) { "python" } else { "python3" }
    Ensure-Command -Name $pythonName -InstallHint "Install Python 3 and ensure it is on PATH."

    if (-not (Test-Path $InstallPath)) {
        New-Item -ItemType Directory -Path $script:TorRepoInstallRoot -Force | Out-Null
        Write-Host "Cloning tor-ip-changer into $InstallPath..." -ForegroundColor Cyan
        git clone --depth 1 https://github.com/seevik2580/tor-ip-changer.git $InstallPath | Out-Null
    }

    $sourceDir = Join-Path $InstallPath "source-code"
    if (-not (Test-Path $sourceDir)) {
        throw "Expected tor-ip-changer source directory not found at $sourceDir."
    }

    $requirementsFile = if ($IsWindows) {
        Join-Path $sourceDir "requirements/windows/pip-requirements.txt"
    }
    else {
        Join-Path $sourceDir "requirements/linux/pip-requirements.txt"
    }

    if (-not (Test-Path $requirementsFile)) {
        throw "Missing requirements file: $requirementsFile"
    }

    Write-Host "Installing upstream tor-ip-changer Python requirements..." -ForegroundColor Cyan
    & $pythonName -m pip install --quiet -r $requirementsFile

    return $InstallPath
}

function Start-TorIPChanger {
    [CmdletBinding()]
    param(
        [string]$InstallPath = $script:TorRepoPath,
        [int]$IntervalSeconds = 30,
        [switch]$NoGui,
        [switch]$PublicApi
    )

    $resolved = Ensure-TorIPChanger -InstallPath $InstallPath
    $sourceDir = Join-Path $resolved "source-code"
    $pythonName = if ($IsWindows) { "python" } else { "python3" }
    $appPath = Join-Path $sourceDir "ipchanger.py"

    if (-not (Test-Path $appPath)) {
        throw "Unable to find tor-ip-changer app script at $appPath"
    }

    $arguments = @(
        $appPath,
        "-a",
        [string]$IntervalSeconds
    )

    if ($NoGui -or -not $IsWindows) {
        $arguments += "--nogui"
    }

    if ($PublicApi) {
        $arguments += "-p"
    }

    Write-Host "Starting streamlined TOR IP changer in headless mode..." -ForegroundColor Green
    $process = Start-Process -FilePath $pythonName -ArgumentList $arguments -WorkingDirectory $sourceDir -PassThru -NoNewWindow
    Start-Sleep -Seconds 2
    return $process
}

function Stop-TorIPChanger {
    [CmdletBinding()]
    param()

    $processes = Get-CimInstance Win32_Process -Filter "Name='python.exe' OR Name='python3' OR Name='ipchanger.exe' OR Name='tor.exe'" -ErrorAction SilentlyContinue
    foreach ($p in $processes) {
        if ($p.Name -in @("python.exe", "python3", "ipchanger.exe", "tor.exe")) {
            Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue
        }
    }

    if ($IsLinux -or $IsMacOS) {
        & killall tor 2>$null
        & killall python 2>$null
        & killall python3 2>$null
    }
}

function Get-TorIP {
    [CmdletBinding()]
    param(
        [string]$TimeoutSeconds = 20
    )

    $pythonName = if ($IsWindows) { "python" } else { "python3" }
    $requestCode = @'
import socket
import urllib.request

socks_host = "127.0.0.1"
socks_port = 9050

try:
    proxied = urllib.request.ProxyHandler({"http": f"socks5://{socks_host}:{socks_port}", "https": f"socks5://{socks_host}:{socks_port}"})
    opener = urllib.request.build_opener(proxied)
    resp = opener.open("http://checkip.amazonaws.com", timeout=15)
    print(resp.read().decode("utf-8").strip())
except Exception as e:
    raise
'@

    & $pythonName -c $requestCode 2>$null
}

Export-ModuleMember -Function Start-TorIPChanger, Stop-TorIPChanger, Get-TorIP, Ensure-TorIPChanger
