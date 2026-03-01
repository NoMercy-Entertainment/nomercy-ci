# Install NoMercy MediaServer on Windows
# Usage: powershell -File install_windows.ps1 -ReleaseTag v0.1.236-perf-improvement
# This script is SCP'd to the VM and executed remotely.

param(
    [Parameter(Mandatory=$true)]
    [string]$ReleaseTag
)

$ErrorActionPreference = 'Stop'
$LogFile = 'C:\ci\install.log'
$ServerLog = 'C:\ci\server.log'
$InstallDir = 'C:\ci'

New-Item -ItemType Directory -Force -Path $InstallDir | Out-Null

function Write-Log {
    param([string]$Message)
    $entry = "[$(Get-Date -Format 'HH:mm:ss')] $Message"
    Write-Host $entry
    Add-Content -Path $LogFile -Value $entry
}

Write-Log "=== NoMercy Windows Install ==="
Write-Log "Tag: $ReleaseTag"

# Extract numeric version: "v0.1.236-perf-improvement" -> "0.1.236"
$Version = $ReleaseTag -replace '^v', '' -replace '-.*$', ''
Write-Log "Version: $Version"

$ExeUrl = "https://github.com/NoMercy-Entertainment/NoMercyMediaServer/releases/download/$ReleaseTag/NoMercyMediaServer-windows-x64.exe"
$ExePath = "$InstallDir\NoMercyMediaServer.exe"

Write-Log "Downloading: $ExeUrl"
try {
    Invoke-WebRequest -Uri $ExeUrl -OutFile $ExePath -UseBasicParsing
    Write-Log "Download complete. Size: $((Get-Item $ExePath).Length) bytes"
} catch {
    Write-Log "ERROR: Download failed — $_"
    exit 1
}

Write-Log "Starting NoMercy MediaServer..."
try {
    $proc = Start-Process -FilePath $ExePath `
        -ArgumentList "--internal-port 7626 --external-port 7626" `
        -RedirectStandardOutput $ServerLog `
        -RedirectStandardError "$InstallDir\server-err.log" `
        -NoNewWindow `
        -PassThru
    Write-Log "Process started. PID: $($proc.Id)"
} catch {
    Write-Log "ERROR: Failed to start process — $_"
    exit 1
}

Write-Log "Waiting 20 seconds for server initialization..."
Start-Sleep -Seconds 20

# Check if process is still running
if ($proc.HasExited) {
    Write-Log "ERROR: Process exited prematurely with code $($proc.ExitCode)"
    if (Test-Path $ServerLog) {
        Write-Log "--- Server output ---"
        Get-Content $ServerLog | ForEach-Object { Write-Log $_ }
    }
    exit 1
}

Write-Log "Server process is running. PID: $($proc.Id)"
Write-Log "=== Install complete ==="
