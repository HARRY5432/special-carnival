# special-carnival

This repo now includes a production-style PowerShell integration for the public Tor-IP-Changer project from https://github.com/seevik2580/tor-ip-changer.

What it does:
- clones the upstream repo into `tools/tor-ip-changer` on first run
- verifies Python and git are available
- installs the required Python packages for the upstream app
- starts the Tor IP changer in headless mode for automation
- exposes PowerShell helpers to start, stop, and fetch the current Tor exit IP

Quick start:

```powershell
. ./TorIPChanger.psm1
Start-TorIPChanger -IntervalSeconds 30 -NoGui
Get-TorIP
Stop-TorIPChanger
```

If you want a single-run integration entry point:

```powershell
./Invoke-TorIPChanger.ps1 -IntervalSeconds 30
```

Notes:
- This is a wrapper around the upstream Tor project and is intended for controlled automation.
- The upstream project is GUI-first and uses its own Tor stack; the PowerShell layer here simply manages and tunes the runtime in a safer, repo-native way.
- On Linux or headless systems, `--nogui` is used automatically.
