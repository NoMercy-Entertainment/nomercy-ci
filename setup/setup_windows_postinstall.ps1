# NoMercy CI -- Windows Template Post-Install Setup
# Runs via SetupComplete.cmd after OOBE (as SYSTEM), or via FirstLogonCommands (as ci user).
# Each section is wrapped in try/catch so we ALWAYS reach sysprep at the end.

$LogFile = 'C:\ci-setup.log'

function Write-Log {
    param([string]$Message)
    $entry = "[$(Get-Date -Format 'HH:mm:ss')] $Message"
    Write-Host $entry
    Add-Content -Path $LogFile -Value $entry
}

Write-Log "=== NoMercy CI Windows Post-Install ==="

# --- Detect drive letters by volume label ---
try {
    $VirtioDrive = ((Get-Volume | Where-Object { $_.FileSystemLabel -match 'virtio' }) | Select-Object -First 1).DriveLetter
    $CIDrive = ((Get-Volume | Where-Object { $_.FileSystemLabel -eq 'CI_DRIVERS' }) | Select-Object -First 1).DriveLetter
} catch {
    Write-Log "WARNING: Failed to detect volumes: $_"
}

if ($VirtioDrive) { Write-Log "VirtIO ISO found on drive ${VirtioDrive}:" }
else { Write-Log "WARNING: VirtIO ISO drive not found by label." }

if ($CIDrive) { Write-Log "CI drivers ISO found on drive ${CIDrive}:" }
else { Write-Log "WARNING: CI drivers ISO drive not found by label." }

# --- 1. Install VirtIO Guest Agent + Drivers ---
try {
    Write-Log "Installing VirtIO guest agent..."
    if ($VirtioDrive) {
        $GuestAgentMsi = Get-ChildItem -Path "${VirtioDrive}:\guest-agent" -Filter "qemu-ga-x86_64.msi" -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($GuestAgentMsi) {
            Start-Process msiexec.exe -ArgumentList "/i `"$($GuestAgentMsi.FullName)`" /qn /norestart" -Wait -NoNewWindow
            Write-Log "VirtIO guest agent installed."
        } else {
            Write-Log "WARNING: qemu-ga-x86_64.msi not found on VirtIO CD."
        }

        $VirtioDriverInstaller = Get-ChildItem -Path "${VirtioDrive}:\" -Filter "virtio-win-gt-x64.msi" -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($VirtioDriverInstaller) {
            Start-Process msiexec.exe -ArgumentList "/i `"$($VirtioDriverInstaller.FullName)`" /qn /norestart" -Wait -NoNewWindow
            Write-Log "VirtIO drivers installed."
        } else {
            Write-Log "WARNING: virtio-win-gt-x64.msi not found."
        }
    } else {
        Write-Log "WARNING: Skipping VirtIO install -- drive not found."
    }
} catch {
    Write-Log "ERROR in VirtIO install: $_"
}

# --- 2. Install OpenSSH Server ---
try {
    Write-Log "Installing OpenSSH Server..."
    Add-WindowsCapability -Online -Name OpenSSH.Server~~~~0.0.1.0
    # Wait for the sshd service to register after capability install
    Write-Log "Waiting for sshd service to register..."
    $retries = 0
    while (-not (Get-Service sshd -ErrorAction SilentlyContinue) -and $retries -lt 30) {
        Start-Sleep -Seconds 2
        $retries++
    }
    if (Get-Service sshd -ErrorAction SilentlyContinue) {
        Set-Service -Name sshd -StartupType Automatic
        Start-Service sshd
        # Wait for sshd to create its config directory
        Start-Sleep -Seconds 3
        Write-Log "OpenSSH Server installed and started."
    } else {
        Write-Log "WARNING: sshd service not found after install. Continuing..."
    }
} catch {
    Write-Log "ERROR in OpenSSH install: $_"
}

# --- 3. Configure SSH ---
try {
    Write-Log "Configuring SSH..."
    $SshdConfig = 'C:\ProgramData\ssh\sshd_config'
    if (Test-Path $SshdConfig) {
        (Get-Content $SshdConfig) -replace '^#?PasswordAuthentication\s+yes', 'PasswordAuthentication no' `
                                  -replace '^#?PubkeyAuthentication\s+no', 'PubkeyAuthentication yes' |
            Set-Content $SshdConfig
        Write-Log "SSH password auth disabled, pubkey enabled."
    } else {
        Write-Log "WARNING: sshd_config not found at $SshdConfig"
    }
} catch {
    Write-Log "ERROR in SSH config: $_"
}

# --- 4. Install CI SSH key ---
try {
    Write-Log "Installing CI SSH public key..."
    $AuthKeysFile = 'C:\ProgramData\ssh\administrators_authorized_keys'
    $PubKeyFile = $null
    if ($CIDrive) { $PubKeyFile = "${CIDrive}:\ci_ed25519.pub" }
    # Fallback: check local copy made during specialize pass
    $LocalPubKey = 'C:\Windows\Setup\Scripts\ci_ed25519.pub'
    if ($PubKeyFile -and (Test-Path $PubKeyFile)) {
        # Found on CI_DRIVERS ISO
    } elseif (Test-Path $LocalPubKey) {
        $PubKeyFile = $LocalPubKey
        Write-Log "Using local fallback SSH key at $LocalPubKey"
    } else {
        $PubKeyFile = $null
    }
    if ($PubKeyFile) {
        # Ensure the ssh directory exists
        $SshDir = Split-Path $AuthKeysFile -Parent
        if (-not (Test-Path $SshDir)) {
            New-Item -Path $SshDir -ItemType Directory -Force | Out-Null
            Write-Log "Created $SshDir"
        }
        $PubKey = Get-Content $PubKeyFile -Raw
        Set-Content -Path $AuthKeysFile -Value $PubKey.Trim()
        icacls $AuthKeysFile /inheritance:r
        icacls $AuthKeysFile /grant "SYSTEM:(F)"
        icacls $AuthKeysFile /grant "Administrators:(F)"
        Write-Log "SSH key installed from $PubKeyFile"
    } else {
        Write-Log "WARNING: SSH public key not found (CIDrive=$CIDrive, path=$PubKeyFile)"
    }
} catch {
    Write-Log "ERROR in SSH key install: $_"
}

# --- 5. Restart SSH ---
try {
    Restart-Service sshd -ErrorAction SilentlyContinue
    Write-Log "SSH service restarted."
} catch {
    Write-Log "ERROR restarting sshd: $_"
}

# --- 6. Firewall rules ---
try {
    Write-Log "Configuring firewall..."
    New-NetFirewallRule -Name "OpenSSH-CI" -DisplayName "OpenSSH Server (CI)" `
        -Protocol TCP -LocalPort 22 -Direction Inbound -Action Allow -ErrorAction SilentlyContinue
    New-NetFirewallRule -Name "NoMercy-CI" -DisplayName "NoMercy MediaServer (CI)" `
        -Protocol TCP -LocalPort 7626 -Direction Inbound -Action Allow -ErrorAction SilentlyContinue
    New-NetFirewallRule -Name "RDP-CI" -DisplayName "Remote Desktop (CI)" `
        -Protocol TCP -LocalPort 3389 -Direction Inbound -Action Allow -ErrorAction SilentlyContinue
    Write-Log "Firewall rules added (22, 3389, 7626)."
} catch {
    Write-Log "ERROR in firewall config: $_"
}

# --- 7. Disable UAC prompts ---
try {
    Write-Log "Disabling UAC prompts..."
    Set-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System" `
        -Name "ConsentPromptBehaviorAdmin" -Value 0
    Write-Log "UAC prompts disabled."
} catch {
    Write-Log "ERROR disabling UAC: $_"
}

# --- 8. Disable Windows Update ---
try {
    Write-Log "Disabling Windows Update..."
    Set-Service -Name wuauserv -StartupType Disabled -ErrorAction SilentlyContinue
    Stop-Service -Name wuauserv -Force -ErrorAction SilentlyContinue
    Write-Log "Windows Update disabled."
} catch {
    Write-Log "ERROR disabling Windows Update: $_"
}

# --- 9. Disable auto-logon ---
try {
    Write-Log "Disabling auto-logon..."
    Remove-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon" `
        -Name "DefaultPassword" -ErrorAction SilentlyContinue
    Set-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon" `
        -Name "AutoAdminLogon" -Value "0"
    Write-Log "Auto-logon disabled."
} catch {
    Write-Log "ERROR disabling auto-logon: $_"
}

# --- 10. Enable Network Discovery ---
try {
    Write-Log "Enabling Network Discovery..."
    # Set network profile to Private (required for discovery)
    Get-NetConnectionProfile | Set-NetConnectionProfile -NetworkCategory Private -ErrorAction SilentlyContinue
    # Enable Network Discovery firewall rules (use internal NETDIS-* names -- locale-independent)
    Get-NetFirewallRule -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -like 'NETDIS-*' } |
        Set-NetFirewallRule -Enabled True -ErrorAction SilentlyContinue
    # Enable required services
    @('FDResPub', 'SSDPSRV', 'upnphost', 'fdPHost') | ForEach-Object {
        Set-Service -Name $_ -StartupType Automatic -ErrorAction SilentlyContinue
        Start-Service -Name $_ -ErrorAction SilentlyContinue
    }
    Write-Log "Network Discovery enabled."
} catch {
    Write-Log "ERROR enabling Network Discovery: $_"
}

# --- 11. Enable Remote Desktop ---
try {
    Write-Log "Enabling Remote Desktop..."
    Set-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server" `
        -Name "fDenyTSConnections" -Value 0
    Set-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp" `
        -Name "UserAuthentication" -Value 0
    Set-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp" `
        -Name "SecurityLayer" -Value 0
    # Enable RDP firewall rules (use internal RemoteDesktop-* names -- locale-independent)
    Get-NetFirewallRule -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -like 'RemoteDesktop-*' } |
        Set-NetFirewallRule -Enabled True -ErrorAction SilentlyContinue
    Set-Service -Name TermService -StartupType Automatic -ErrorAction SilentlyContinue
    Start-Service -Name TermService -ErrorAction SilentlyContinue
    Write-Log "Remote Desktop enabled."
} catch {
    Write-Log "ERROR enabling Remote Desktop: $_"
}

# --- 12. Sysprep + shutdown (MUST always run) ---
Write-Log "Running sysprep (generalize + shutdown)..."
Write-Log "The VM will shut down after sysprep. The outer script will convert it to a template."

Start-Sleep -Seconds 10

& "$env:SystemRoot\System32\Sysprep\sysprep.exe" /generalize /oobe /shutdown /quiet

Write-Log "Sysprep initiated. Waiting for shutdown..."
