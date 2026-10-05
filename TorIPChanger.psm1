#Requires -Version 5.1
<#
.SYNOPSIS
    TorIPChanger wrapper module for orchestrator integration.
    Provides start, stop, and IP check functions for Tor automation.
#>

Set-StrictMode -Version Latest

$script:TorRepoRoot = Join-Path $PSScriptRoot 'tools'
$script:TorRepoPath = Join-Path $script:TorRepoRoot 'tor-ip-changer'

function Ensure-Command {
    param(
        [Parameter(Mandatory=$true)]
        [string]$Name,
        [string]$InstallHint
    )

    if (-not (Get-Command $Name -ErrorAction SilentlyContinue)) {
        throw "Required command ${Name} not found. ${InstallHint}"
    }
}

function Ensure-TorIPChanger {
    [CmdletBinding()]
    param([string]$InstallPath = $script:TorRepoPath)

    Ensure-Command -Name git -InstallHint 'Install Git.'

    $pythonName = if ($IsWindows) { 'python' } else { 'python3' }
    Ensure-Command -Name $pythonName -InstallHint 'Install Python 3.'

    if (-not (Test-Path $InstallPath)) {
        New-Item -ItemType Directory -Path $script:TorRepoRoot -Force | Out-Null
        Write-Host "Cloning tor-ip-changer..." -ForegroundColor Cyan
        & git clone --depth 1 https://github.com/seevik2580/tor-ip-changer.git $InstallPath | Out-Null
    }

    $sourceDir = Join-Path $InstallPath 'source-code'
    if (-not (Test-Path $sourceDir)) {
        throw "tor-ip-changer source not found at ${sourceDir}."
    }

    $reqFile = if ($IsWindows) {
        Join-Path $sourceDir 'requirements\windows\pip-requirements.txt'
    } else {
        Join-Path $sourceDir 'requirements/linux/pip-requirements.txt'
    }

    if (-not (Test-Path $reqFile)) {
        throw "Missing requirements: ${reqFile}"
    }

    Write-Host "Installing tor-ip-changer requirements..." -ForegroundColor Cyan
    & $pythonName -m pip install --quiet -r $reqFile

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
    $sourceDir = Join-Path $resolved 'source-code'
    $pythonName = if ($IsWindows) { 'python' } else { 'python3' }
    $appPath = Join-Path $sourceDir 'ipchanger.py'

    if (-not (Test-Path $appPath)) {
        throw "tor-ip-changer script not found at ${appPath}"
    }

    $arguments = @($appPath, '-a', [string]$IntervalSeconds)
    if ($NoGui -or -not $IsWindows) {
        $arguments += '--nogui'
    }
    if ($PublicApi) {
        $arguments += '-p'
    }

    Write-Host 'Starting Tor IP changer...' -ForegroundColor Green
    $process = Start-Process -FilePath $pythonName -ArgumentList $arguments -WorkingDirectory $sourceDir -PassThru -NoNewWindow
    Start-Sleep -Seconds 2
    return $process
}

function Stop-TorIPChanger {
    [CmdletBinding()]
    param()

    $names = @('python.exe', 'python3', 'ipchanger.exe', 'tor.exe')
    $processes = Get-CimInstance Win32_Process -ErrorAction SilentlyContinue
    foreach ($p in $processes) {
        if ($p.Name -in $names) {
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
    param()

    $pythonName = if ($IsWindows) { 'python' } else { 'python3' }
    $code = @'
import urllib.request
proxy_h = urllib.request.ProxyHandler({'http': 'socks5://127.0.0.1:9050', 'https': 'socks5://127.0.0.1:9050'})
try:
    opener = urllib.request.build_opener(proxy_h)
    r = opener.open('http://checkip.amazonaws.com', timeout=15)
    print(r.read().decode('utf-8').strip())
except:
    pass
'@

    $output = & $pythonName -c $code 2>$null
    if ($output) { return ($output | Select-Object -First 1).Trim() }
    return $null
}

Export-ModuleMember -Function Start-TorIPChanger, Stop-TorIPChanger, Get-TorIP, Ensure-TorIPChanger
