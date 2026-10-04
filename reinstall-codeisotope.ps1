#Requires -Version 5.1
<#
.SYNOPSIS
    Wipes any previously installed version of the `codeisotope` npm package
    (global OR local, any version) and reinstalls it fresh from the registry.

.DESCRIPTION
    1. Detects and removes the global install (any version).
    2. Detects and removes a local install in the current project (any version).
    3. Prunes the npm cache so no stale tarball/metadata is reused.
    4. Reinstalls codeisotope globally at the latest version.

.PARAMETER Scope
    Global  -> force-install globally (default)
    Local   -> install into the current directory's package.json
    Both    -> clean both locations, then install globally

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\reinstall-codeisotope.ps1
#>

[CmdletBinding()]
param(
    [ValidateSet('Global', 'Local', 'Both')]
    [string]$Scope = 'Global',

    # Pin a specific version instead of the newest one
    [string]$Version = '',

    [switch]$KeepCache
)

$ErrorActionPreference = 'Continue'
$Package = 'codeisotope'

function Write-Step { param([string]$m) Write-Host "==> $m" -ForegroundColor Cyan }
function Write-Ok   { param([string]$m) Write-Host "    [ok] $m" -ForegroundColor Green }
function Write-Warn { param([string]$m) Write-Host "    [--] $m" -ForegroundColor Yellow }
function Write-Err  { param([string]$m) Write-Host "    [!!] $m" -ForegroundColor Red }

function Test-GlobalPackage {
    param([string]$Name)
    $root = (& npm root -g 2>$null)
    if (-not $root) { return $false }
    return (Test-Path -LiteralPath (Join-Path $root $Name))
}

function Test-LocalPackage {
    param([string]$Name)
    $here = (& npm root 2>$null)
    if (-not $here) { return $false }
    return (Test-Path -LiteralPath (Join-Path $here $Name))
}

Write-Host ''
Write-Host '  codeisotope clean reinstall' -ForegroundColor White
Write-Host '  --------------------------' -ForegroundColor DarkGray
Write-Host "  node    : $(& node -v)"
Write-Host "  npm     : $(& npm -v)"
Write-Host "  scope   : $Scope"
Write-Host ''

# ---------------------------------------------------------------- 1. UNINSTALL
if ($Scope -in @('Global', 'Both')) {
    Write-Step 'Removing global installation (any version)'
    if (Test-GlobalPackage -Name $Package) {
        & npm uninstall -g $Package 2>&1 | Out-Null
        if (Test-GlobalPackage -Name $Package) {
            Write-Warn "npm uninstall -g $Package left files behind, forcing removal"
            $root = (& npm root -g 2>$null)
            $target = Join-Path $root $Package
            Remove-Item -LiteralPath $target -Recurse -Force -ErrorAction SilentlyContinue
        }
        if (Test-GlobalPackage -Name $Package) {
            Write-Err "Could not remove global $Package"
        } else {
            Write-Ok "Global $Package removed"
        }
    } else {
        Write-Ok "No global $Package found (nothing to remove)"
    }
}

if ($Scope -in @('Local', 'Both')) {
    Write-Step 'Removing local installation in this project (any version)'
    if (Test-LocalPackage -Name $Package) {
        & npm uninstall $Package 2>&1 | Out-Null
        if (Test-LocalPackage -Name $Package) {
            Write-Warn "npm uninstall $Package left files behind, forcing removal"
            $here = (& npm root 2>$null)
            Remove-Item -LiteralPath (Join-Path $here $Package) -Recurse -Force -ErrorAction SilentlyContinue
        }
        if (Test-LocalPackage -Name $Package) {
            Write-Err "Could not remove local $Package"
        } else {
            Write-Ok "Local $Package removed"
        }
    } else {
        Write-Ok "No local $Package found (nothing to remove)"
    }
}

# ---------------------------------------------------------------- 2. CLEAN CACHE
if (-not $KeepCache) {
    Write-Step 'Cleaning npm cache (prevents stale version reuse)'
    & npm cache clean --force 2>&1 | Out-Null
    Write-Ok 'npm cache cleaned'
}

# ---------------------------------------------------------------- 3. INSTALL
$target = if ($Version) { "$Package@$Version" } else { "$Package@latest" }

if ($Scope -eq 'Local') {
    Write-Step "Installing $target locally in $((Get-Location).Path)"
    & npm install $target
} else {
    Write-Step "Installing $target globally"
    & npm install -g $target
}

if ($LASTEXITCODE -ne 0) {
    Write-Host ''
    Write-Err "npm install failed (exit code $LASTEXITCODE)"
    exit 1
}

# ---------------------------------------------------------------- 4. VERIFY
Write-Step 'Verifying install'
$installed = $null
if ($Scope -eq 'Local') {
    $installed = (& npm ls $Package --depth=0 2>$null)
} else {
    $installed = (& npm ls -g $Package --depth=0 2>$null)
}
Write-Host $installed

if ($installed -match [regex]::Escape($Package)) {
    Write-Host ''
    Write-Host '  Done - clean reinstall complete.' -ForegroundColor Green
    Write-Host ''
} else {
    Write-Host ''
    Write-Warn 'Install command succeeded but the package was not listed. Check the output above.'
    Write-Host ''
    exit 1
}
