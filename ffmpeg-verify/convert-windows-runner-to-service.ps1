# Converts the Windows verification runner from a logon Scheduled Task to a
# Windows service, and proves NVENC still works from the service account.
#
# The task form runs inside the interactive session: it shows a console window,
# and it disappears the moment the user logs out. A service starts at boot,
# needs nobody logged in, and stays out of the way.
#
# On Windows there is no svc.cmd to call — the service is created by
# re-running config.cmd with --runasservice, so the runner has to be
# re-registered rather than converted in place.
#
# The NVENC check is not optional. This host is the fleet's only NVIDIA hardware,
# and a service runs in session 0 where GPU access can behave differently. If
# NVENC broke here, windows-x86_64 would keep reporting a pass while quietly
# downgrading its hardware test to a skip — the exact failure this fleet exists
# to prevent.
#
# Must run elevated.
param(
    [Parameter(Mandatory)][string]$Token,
    [string]$InstallRoot = "C:\actions-runner-ffmpeg",
    [string]$TaskName = "GitHubActionsRunner-ffmpeg-verify-windows",
    [string]$Org = "NoMercy-Entertainment",
    [string]$Name = "ffmpeg-verify-windows",
    [string]$Labels = "ffmpeg-verify,windows-x86_64,nvenc",
    [string]$ServiceAccount = "NT AUTHORITY\NETWORK SERVICE"
)

$ErrorActionPreference = 'Stop'

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).
    IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) { throw "This script must run elevated." }

Write-Host "── Removing the logon task ──"
if (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue) {
    Stop-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
    Write-Host "Removed $TaskName."
}
else { Write-Host "No task registered." }

# The listener holds its own binaries open; reconfiguration fails on a locked file.
Get-Process -Name 'Runner.Listener' -ErrorAction SilentlyContinue |
    Where-Object { $_.Path -like "$InstallRoot*" } |
    ForEach-Object { $_.Kill(); $_.WaitForExit(15000) }

Push-Location $InstallRoot
try {
    Write-Host "`n── Re-registering as a service ──"
    # Tolerated: a runner already removed from the org has nothing to unregister.
    & "$InstallRoot\config.cmd" remove --token $Token 2>&1 | Out-Null

    & "$InstallRoot\config.cmd" --unattended --replace `
        --url "https://github.com/$Org" `
        --token $Token `
        --name $Name `
        --labels $Labels `
        --work '_work' `
        --runasservice `
        --windowslogonaccount $ServiceAccount
    if ($LASTEXITCODE -ne 0) { throw "config.cmd failed with exit $LASTEXITCODE" }
}
finally { Pop-Location }

$service = Get-Service | Where-Object { $_.Name -like 'actions.runner*' } | Select-Object -First 1
if (-not $service) { throw "No runner service was registered." }
Set-Service -Name $service.Name -StartupType Automatic
if ($service.Status -ne 'Running') { Start-Service -Name $service.Name }
$service.Refresh()
Write-Host "Service $($service.Name): $((Get-Service $service.Name).Status), startup $((Get-Service $service.Name).StartType)"

Write-Host "`n── Proving NVENC works from the service account ──"
# Runs ffmpeg as the account the service uses, in session 0, so the answer
# reflects how verification jobs will actually execute.
$probeDir = Join-Path $env:ProgramData 'nomercy-nvenc-probe'
Remove-Item $probeDir -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Path $probeDir -Force | Out-Null
icacls $probeDir /grant "$($ServiceAccount):(OI)(CI)F" | Out-Null

$ffmpeg = Get-ChildItem -Path $InstallRoot -Filter 'ffmpeg.exe' -Recurse -ErrorAction SilentlyContinue |
    Select-Object -First 1 -ExpandProperty FullName

if (-not $ffmpeg) {
    Write-Host "::warning::No ffmpeg.exe on disk to probe with — the next verify job will answer this."
}
else {
    $probeTask = 'nomercy-nvenc-session0-probe'
    $inner = "`"$ffmpeg`" -hide_banner -y -f lavfi -i testsrc=duration=1:size=640x480:rate=30 " +
             "-c:v h264_nvenc `"$probeDir\out.mp4`" > `"$probeDir\log.txt`" 2>&1 & " +
             "echo %ERRORLEVEL% > `"$probeDir\exit.txt`""
    schtasks /create /tn $probeTask /tr "cmd /c $inner" /sc once /st 00:00 `
        /ru $ServiceAccount /rl HIGHEST /f | Out-Null
    schtasks /run /tn $probeTask | Out-Null

    for ($i = 0; $i -lt 30; $i++) {
        Start-Sleep -Seconds 2
        if (Test-Path "$probeDir\exit.txt") { break }
    }
    schtasks /delete /tn $probeTask /f | Out-Null

    $code = "$(Get-Content "$probeDir\exit.txt" -ErrorAction SilentlyContinue | Select-Object -First 1)".Trim()
    $size = (Get-Item "$probeDir\out.mp4" -ErrorAction SilentlyContinue).Length
    if ($code -eq '0' -and $size -gt 0) {
        Write-Host "NVENC OK from session 0: exit 0, $size bytes."
    }
    else {
        Write-Host "NVENC FAILED from session 0 (exit '$code', $size bytes):"
        Get-Content "$probeDir\log.txt" -ErrorAction SilentlyContinue | Select-Object -Last 8
        Write-Host "A service that cannot encode is worse than a visible console — revert to the logon task."
    }
}

Write-Host "`nDone."
