# Install all CI tools + GitHub Actions runner on Windows
# Run as Administrator in PowerShell.
#
# Usage: .\install_windows_runner.ps1 [-RunnerVersion "2.322.0"]

param(
    [string]$RunnerVersion = "2.322.0"
)

$ErrorActionPreference = "Stop"

function Log { param([string]$msg) Write-Host "[$(Get-Date -Format 'HH:mm:ss')] $msg" }

Log "Installing CI tools on Windows $(Get-CimInstance Win32_OperatingSystem | Select-Object -ExpandProperty Caption)..."

########################################
# Chocolatey
########################################

if (-not (Get-Command choco -ErrorAction SilentlyContinue)) {
    Log "Installing Chocolatey..."
    Set-ExecutionPolicy Bypass -Scope Process -Force
    [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.ServicePointManager]::SecurityProtocol -bor 3072
    Invoke-Expression ((New-Object System.Net.WebClient).DownloadString('https://community.chocolatey.org/install.ps1'))
}

# Refresh PATH
$env:Path = [System.Environment]::GetEnvironmentVariable("Path", "Machine") + ";" + [System.Environment]::GetEnvironmentVariable("Path", "User")

########################################
# Languages and runtimes
########################################

Log "Installing languages..."
choco install -y `
    nodejs-lts `
    python312 `
    golang `
    ruby `
    rustup.install `
    php `
    composer

# Node 22 + corepack + yarn
npm install -g n corepack yarn
corepack enable

# .NET
choco install -y `
    dotnet-8.0-sdk `
    dotnet-9.0-sdk `
    dotnet-sdk

# Java
choco install -y `
    temurin8 `
    temurin11 `
    temurin17 `
    temurin21 `
    temurin

# Set JAVA_HOME env vars
$javaBase = "C:\Program Files\Eclipse Adoptium"
$javaDirs = Get-ChildItem $javaBase -Directory -ErrorAction SilentlyContinue | Sort-Object Name
foreach ($dir in $javaDirs) {
    $ver = $dir.Name -replace '^jdk-(\d+).*', '$1'
    [Environment]::SetEnvironmentVariable("JAVA_HOME_${ver}_X64", $dir.FullName, "Machine")
}
# Default to 17
$java17 = $javaDirs | Where-Object { $_.Name -like "jdk-17*" } | Select-Object -First 1
if ($java17) {
    [Environment]::SetEnvironmentVariable("JAVA_HOME", $java17.FullName, "Machine")
}

########################################
# Build tools
########################################

Log "Installing build tools..."
choco install -y `
    cmake --installargs 'ADD_CMAKE_TO_PATH=System' `
    ninja `
    gradle `
    maven `
    ant

########################################
# Android SDK
########################################

Log "Installing Android SDK..."
$androidHome = "C:\Android\sdk"
[Environment]::SetEnvironmentVariable("ANDROID_HOME", $androidHome, "Machine")
[Environment]::SetEnvironmentVariable("ANDROID_SDK_ROOT", $androidHome, "Machine")
$env:ANDROID_HOME = $androidHome

New-Item -ItemType Directory -Force -Path "$androidHome\cmdline-tools" | Out-Null
$cmdlineUrl = "https://dl.google.com/android/repository/commandlinetools-win-11076708_latest.zip"
Invoke-WebRequest -Uri $cmdlineUrl -OutFile "$env:TEMP\cmdline-tools.zip"
Expand-Archive -Path "$env:TEMP\cmdline-tools.zip" -DestinationPath "$env:TEMP\cmdline-extract" -Force
Move-Item "$env:TEMP\cmdline-extract\cmdline-tools" "$androidHome\cmdline-tools\latest" -Force
Remove-Item "$env:TEMP\cmdline-tools.zip", "$env:TEMP\cmdline-extract" -Recurse -Force

$env:Path += ";$androidHome\cmdline-tools\latest\bin;$androidHome\platform-tools"

# Accept licenses and install components
$yes = "y`n" * 20
$yes | & "$androidHome\cmdline-tools\latest\bin\sdkmanager.bat" --licenses 2>$null
& "$androidHome\cmdline-tools\latest\bin\sdkmanager.bat" `
    "platform-tools" `
    "platforms;android-34" "platforms;android-35" "platforms;android-36" `
    "build-tools;34.0.0" "build-tools;35.0.0" "build-tools;35.0.1" `
    "build-tools;36.0.0" "build-tools;36.1.0" `
    "ndk;27.3.13750724" "ndk;28.2.13676358" "ndk;29.0.14206865"

########################################
# CLI tools
########################################

Log "Installing CLI tools..."
choco install -y `
    gh `
    awscli `
    azure-cli `
    kubernetes-cli `
    kubernetes-helm `
    packer `
    jq `
    yq

########################################
# Docker
########################################

Log "Installing Docker..."
choco install -y docker-desktop

########################################
# Browsers
########################################

Log "Installing browsers..."
choco install -y `
    googlechrome `
    firefox

########################################
# Git + OpenSSH
########################################

choco install -y git openssh
Add-WindowsCapability -Online -Name OpenSSH.Server~~~~0.0.1.0 -ErrorAction SilentlyContinue
Start-Service sshd -ErrorAction SilentlyContinue
Set-Service -Name sshd -StartupType Automatic -ErrorAction SilentlyContinue

########################################
# GitHub Actions runner
########################################

Log "Installing GitHub Actions runner v${RunnerVersion}..."
$runnerDir = "C:\actions-runner"
New-Item -ItemType Directory -Force -Path $runnerDir | Out-Null
Set-Location $runnerDir

$runnerUrl = "https://github.com/actions/runner/releases/download/v${RunnerVersion}/actions-runner-win-x64-${RunnerVersion}.zip"
Invoke-WebRequest -Uri $runnerUrl -OutFile "$env:TEMP\runner.zip"
Expand-Archive -Path "$env:TEMP\runner.zip" -DestinationPath $runnerDir -Force
Remove-Item "$env:TEMP\runner.zip"

########################################
# Update system PATH
########################################

$pathAdditions = @(
    "$androidHome\cmdline-tools\latest\bin",
    "$androidHome\platform-tools",
    "C:\Program Files\CMake\bin"
)
$currentPath = [Environment]::GetEnvironmentVariable("Path", "Machine")
foreach ($p in $pathAdditions) {
    if ($currentPath -notlike "*$p*") {
        $currentPath += ";$p"
    }
}
[Environment]::SetEnvironmentVariable("Path", $currentPath, "Machine")

Log "Windows runner setup complete."
