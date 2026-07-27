# Installs a persistent GitHub Actions runner on a Windows host and registers it
# against the NoMercy org with a fixed label set.
#
# This host is the fleet's only NVENC hardware, and NVENC cannot be reached
# through WSL2 or a container — cuInit succeeds and the encode then dies with
# SIGFPE. Verifying it means running natively here.
#
# Installs as a Windows SERVICE when elevated, and falls back to a per-user
# logon Scheduled Task when not. The service is strongly preferred: the task
# form runs in the interactive session, so it puts a console window on the
# owner's desktop and disappears when they log out.
#
# Session 0 does not break NVENC here — verified on an RTX 2080 SUPER with the
# service running as NT AUTHORITY\NETWORK SERVICE: 23 passed, 0 failed, with the
# NVENC encode among the passes. Re-check that after a driver or GPU change,
# because a broken NVENC in session 0 would look like a normal test failure on
# the one platform nothing else in the fleet can cover.
param(
    [Parameter(Mandatory)][string]$Token,
    [string]$Name = "ffmpeg-verify-windows",
    [string]$Labels = "ffmpeg-verify,windows-x86_64,nvenc",
    [string]$Org = "NoMercy-Entertainment",
    [string]$Version = "2.336.0",
    [string]$InstallRoot = "C:\actions-runner-ffmpeg",
    [string]$ServiceAccount = "NT AUTHORITY\NETWORK SERVICE"
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

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).
    IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

# There is no svc.cmd on Windows — the service is created by config.cmd itself,
# so the choice has to be made at registration time rather than converted after.
# --replace so re-running this re-homes an existing registration instead of
# leaving a dead duplicate in the org runner list.
$configArgs = @(
    '--unattended', '--replace',
    '--url', "https://github.com/$Org",
    '--token', $Token,
    '--name', $Name,
    '--labels', $Labels,
    '--work', '_work'
)
if ($isAdmin) {
    $configArgs += @('--runasservice', '--windowslogonaccount', $ServiceAccount)
}

& (Join-Path $InstallRoot 'config.cmd') @configArgs
if ($LASTEXITCODE -ne 0) { throw "config.cmd failed with exit $LASTEXITCODE" }

if ($isAdmin) {
    $service = Get-Service | Where-Object { $_.Name -like 'actions.runner*' } | Select-Object -First 1
    if (-not $service) { throw 'No runner service was registered.' }
    Set-Service -Name $service.Name -StartupType Automatic
    if ((Get-Service $service.Name).Status -ne 'Running') { Start-Service -Name $service.Name }
    Write-Host "✅ $Name registered as service $($service.Name) with labels: $Labels"
}
else {
    Write-Host '::warning::Not elevated — falling back to a logon task. It shows a console window and stops at logout.'
    $action = New-ScheduledTaskAction -Execute (Join-Path $InstallRoot 'run.cmd') -WorkingDirectory $InstallRoot
    $trigger = New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
        -ExecutionTimeLimit ([TimeSpan]::Zero) -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1)

    Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger `
        -Settings $settings -Description "NoMercy ffmpeg RC verification runner" | Out-Null
    Start-ScheduledTask -TaskName $taskName
    Write-Host "✅ $Name registered as a logon task with labels: $Labels"
}
