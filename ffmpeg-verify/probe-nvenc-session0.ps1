# Answers one question: can this host encode with NVENC from a service account
# in session 0, the way the runner service now executes jobs?
#
# Worth its own script because the failure it guards against is silent. If NVENC
# stops working under the service, the capability probe still sees the GPU via
# nvidia-smi, the suite still runs the encode, and the only signal is a failed
# test on the one platform nothing else in the fleet can cover.
#
# Must run elevated (registering a task as another principal requires it).
param(
    [string]$ProbeDir = "C:\Users\Public\nvenc-probe",
    [string]$ServiceAccount = "NT AUTHORITY\NETWORK SERVICE",
    [string]$TaskName = "nomercy-nvenc-session0"
)

$ErrorActionPreference = 'Stop'

$ffmpeg = Join-Path $ProbeDir 'ffmpeg.exe'
if (-not (Test-Path $ffmpeg)) { throw "No ffmpeg.exe at $ffmpeg" }

$output = Join-Path $ProbeDir 'out.mp4'
$logFile = Join-Path $ProbeDir 'log.txt'
$exitFile = Join-Path $ProbeDir 'exit.txt'
foreach ($stale in $output, $logFile, $exitFile) {
    if (Test-Path $stale) { Remove-Item $stale -Force }
}

$inner = '"' + $ffmpeg + '" -hide_banner -y -f lavfi -i testsrc=duration=2:size=1280x720:rate=30 ' +
         '-c:v h264_nvenc "' + $output + '" > "' + $logFile + '" 2>&1 & ' +
         'echo %ERRORLEVEL% > "' + $exitFile + '"'

if (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue) {
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
}

$action = New-ScheduledTaskAction -Execute 'cmd.exe' -Argument ('/c ' + $inner)
$principal = New-ScheduledTaskPrincipal -UserId $ServiceAccount -LogonType ServiceAccount -RunLevel Highest
Register-ScheduledTask -TaskName $TaskName -Action $action -Principal $principal | Out-Null
Start-ScheduledTask -TaskName $TaskName

for ($i = 0; $i -lt 45; $i++) {
    Start-Sleep -Seconds 2
    if (Test-Path $exitFile) { break }
}
Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false

$code = "$(Get-Content $exitFile -ErrorAction SilentlyContinue | Select-Object -First 1)".Trim()
$size = (Get-Item $output -ErrorAction SilentlyContinue).Length

Write-Host "SESSION0_EXIT=$code"
Write-Host "SESSION0_BYTES=$size"
Write-Host "SESSION0_ACCOUNT=$ServiceAccount"
Get-Content $logFile -ErrorAction SilentlyContinue | Select-Object -Last 6

if ($code -eq '0' -and $size -gt 0) { Write-Host 'RESULT=NVENC_OK' }
else { Write-Host 'RESULT=NVENC_BROKEN' }
