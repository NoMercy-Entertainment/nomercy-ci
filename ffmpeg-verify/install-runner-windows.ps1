# Installs a persistent GitHub Actions runner on a Windows host and registers it
# against the NoMercy org with a fixed label set.
#
# This host is the fleet's only NVENC hardware, and NVENC cannot be reached
# through WSL2 or a container — cuInit succeeds and the encode then dies with
# SIGFPE. Verifying it means running natively here.
#
# Registers a per-user logon Scheduled Task rather than a Windows service:
# service install needs elevation, and a UAC prompt defeats the point of an
# unattended fleet. The cost is that the runner comes up at logon rather than at
# boot; a job queued while the machine is off simply waits.
param(
    [Parameter(Mandatory)][string]$Token,
    [string]$Name = "ffmpeg-verify-windows",
    [string]$Labels = "ffmpeg-verify,windows-x86_64,nvenc",
    [string]$Org = "NoMercy-Entertainment",
    [string]$Version = "2.336.0",
    [string]$InstallRoot = "C:\actions-runner-ffmpeg"
)

$ErrorActionPreference = 'Stop'

Write-Host "─── $Name :: windows-x64 :: $Labels ───"

if (-not (Test-Path $InstallRoot)) {
    New-Item -ItemType Directory -Path $InstallRoot -Force | Out-Null
}

$taskName = "GitHubActionsRunner-$Name"

# Stop an existing instance before touching its files, or config.sh will fail on
# a locked assembly and leave a half-registered runner in the org list.
$existing = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
if ($existing) {
    Stop-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
    Unregister-ScheduledTask -TaskName $taskName -Confirm:$false
}
Get-Process -Name 'Runner.Listener' -ErrorAction SilentlyContinue |
    Where-Object { $_.Path -like "$InstallRoot*" } | Stop-Process -Force

if (-not (Test-Path (Join-Path $InstallRoot 'config.cmd'))) {
    $zip = Join-Path $env:TEMP "actions-runner-win-x64-$Version.zip"
    $url = "https://github.com/actions/runner/releases/download/v$Version/actions-runner-win-x64-$Version.zip"
    Write-Host "Downloading runner $Version…"
    Invoke-WebRequest -Uri $url -OutFile $zip -UseBasicParsing
    Expand-Archive -Path $zip -DestinationPath $InstallRoot -Force
    Remove-Item $zip -Force
}

if (Test-Path (Join-Path $InstallRoot '.runner')) {
    Write-Host 'Runner already configured; removing before re-registering.'
    & (Join-Path $InstallRoot 'config.cmd') remove --token $Token 2>&1 | Out-Null
}

# --replace so re-running this re-homes an existing registration instead of
# leaving a dead duplicate in the org runner list.
& (Join-Path $InstallRoot 'config.cmd') --unattended --replace `
    --url "https://github.com/$Org" `
    --token $Token `
    --name $Name `
    --labels $Labels `
    --work '_work'
if ($LASTEXITCODE -ne 0) { throw "config.cmd failed with exit $LASTEXITCODE" }

$action = New-ScheduledTaskAction -Execute (Join-Path $InstallRoot 'run.cmd') -WorkingDirectory $InstallRoot
$trigger = New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME
$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
    -ExecutionTimeLimit ([TimeSpan]::Zero) -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1)

Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger `
    -Settings $settings -Description "NoMercy ffmpeg RC verification runner" | Out-Null
Start-ScheduledTask -TaskName $taskName

Write-Host "✅ $Name registered with labels: $Labels"
