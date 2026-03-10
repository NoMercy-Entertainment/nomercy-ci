# PRD: NoMercy MediaServer Cross-Platform Automated Test Lab

## 1. Overview

This document defines the architecture, automation, infrastructure, and validation strategy
for a fully automated cross-platform test matrix for NoMercy MediaServer.

The lab runs on:

- Proxmox Virtual Environment (Community Edition)
- 1TB SSD RAID10
- TrueNAS for storage/backups
- No paid CI services

The system must automatically:

1. Spawn test environments
2. Install NoMercy MediaServer
3. Launch in headless mode
4. Verify HTTP/web availability
5. Collect logs
6. Destroy environment
7. Support Linux (LXC) + Windows 10 (VM)
8. Optionally support ARM (experimental)

---

## 2. Goals

### Primary Goals

- Validate all production binaries per release
- Test installers on Windows 10
- Test headless + web UI mode
- Test on Arch Linux (nerd compliance requirement)
- Fully automated lifecycle (no GUI usage)

### Non-Goals

- Kernel/driver testing
- macOS virtualization (requires Apple hardware)
- Enterprise-grade HA clustering
- GPU passthrough testing (v1)

---

## 3. Supported Test Matrix

### Linux (LXC Containers)

| OS        | Type | Arch     | Priority |
|-----------|------|----------|----------|
| Ubuntu LTS | LXC | x86_64 | High |
| Debian Stable | LXC | x86_64 | High |
| Fedora | LXC | x86_64 | Medium |
| Arch Linux | LXC | x86_64 | Mandatory |

Optional:
- ARM64 (QEMU emulated container or VM, slow mode only)

### Windows

| OS | Type | Arch | Priority |
|----|------|------|----------|
| Windows 10 Pro | Full VM | x86_64 | High |

---

## 4. Architecture

### 4.1 Host Layer

- Proxmox VE (single node)
- RAID10 SSD for:
  - Active containers
  - Active VMs
  - Templates
- TrueNAS mounted via NFS for:
  - ISO storage
  - Log artifacts
  - Backups

---

### 4.2 Container vs VM Policy

Linux → LXC only  
Windows → Full KVM VM  
ARM → Optional QEMU VM  

Rationale:
- LXC = faster startup, lower memory, higher density
- Windows requires full virtualization

---

## 5. One-Time Setup Requirements

### 5.1 Proxmox Preparation

Install:
- jq
- curl
- python3
- openssh-client

Enable:
- qemu-guest-agent support
- NFS mount to TrueNAS

---

### 5.2 TrueNAS Mount

Mount NFS:

/mnt/nomercy-artifacts

Used for:
- Logs
- Test output
- Nightly backups

---

## 6. Base Templates

### 6.1 Linux LXC Templates

Use official Proxmox LXC templates.

Create base containers:

- ubuntu-24
- debian-12
- fedora-40
- arch

Install inside each before converting to template:

- curl
- tar
- openssh-server
- sudo
- net-tools
- systemd enabled
- firewall disabled
- dedicated CI user: `ci`
- SSH key installed

Convert to template:

pct set <CTID> --template 1

---

### 6.2 Windows 10 Template

Manual once:

1. Install Windows 10 Pro
2. Install VirtIO drivers
3. Install:
   - OpenSSH Server
   - PowerShell 7
4. Enable WinRM
5. Disable UAC prompts for CI user
6. Create user `ci`
7. Allow firewall:
   - 22
   - Web UI port
8. Install Cloudbase-Init
9. Run sysprep
10. Convert to template

qm template <VMID>

---

## 7. Automation System

Root directory:

/opt/nomercy-ci/

Structure:

/opt/nomercy-ci/
  config.sh
  run_matrix.sh
  spawn_lxc.sh
  spawn_windows.sh
  install_linux.sh
  install_windows.ps1
  test_http.sh
  collect_logs.sh

---

## 8. Lifecycle Flow

### 8.1 Linux Flow (LXC)

1. Clone template (linked clone)
2. Set CPU/RAM limits
3. Start container
4. Wait for SSH
5. Download release binary
6. Extract + chmod
7. Launch headless
8. Verify HTTP endpoint
9. Collect logs
10. Destroy container

---

### 8.2 Windows Flow

1. Clone VM template
2. Start VM
3. Detect IP via guest agent
4. SSH or WinRM into VM
5. Download installer
6. Run silent install
7. Start service
8. Verify HTTP endpoint
9. Collect logs
10. Shutdown + destroy VM

---

## 9. Validation Requirements

Each test must validate:

- Process starts successfully
- No crash within 30 seconds
- Web endpoint responds 200 OK
- Port binding correct
- Log file contains no fatal errors

Optional:
- Memory usage below threshold
- CPU usage stable

---

## 10. Release Artifact Handling

Source:
GitHub release URL

Configurable variable:
NOMERCY_URL

System must support:
- linux-x64
- linux-arm64
- windows-x64
- mac (if later added)

---

## 11. Networking

Bridge: vmbr0  
Containers get DHCP IP  
Firewall rules allow:

- SSH (22)
- Web UI (configurable, default 8080)

No external exposure required.

---

## 12. Resource Limits

### Linux Containers

- 2–4 cores
- 2–4GB RAM
- 10GB disk

### Windows VM

- 4 cores
- 8GB RAM
- 60GB disk

---

## 13. ARM Mode (Experimental)

ARM support requires:

- QEMU emulation
- aarch64 VM
- Significant performance reduction

Usage policy:
- Not part of default CI
- Run nightly only

---

## 14. Logging & Artifacts

All logs stored in:

/mnt/nomercy-artifacts/<release>/<os>/

Includes:

- server.log
- install log
- HTTP test output
- system info

---

## 15. Destruction Policy

After each test:

- Stop environment
- Destroy container/VM
- Free disk immediately

No persistent test instances allowed.

---

## 16. Performance Targets

Linux LXC boot time:
< 5 seconds

Windows VM boot:
< 90 seconds

Full matrix runtime:
< 15 minutes

---

## 17. Security

- No root SSH login
- Dedicated CI user
- SSH key-only authentication
- Containers unprivileged
- Windows VM isolated network

---

## 18. Future Enhancements

- Parallel execution
- Python-based orchestrator
- Automatic GitHub webhook trigger
- Web dashboard
- Benchmark suite
- ARM hardware node
- macOS node (Apple hardware)

---

## 19. Risks

- Windows updates interfering
- Arch rolling breakage
- ARM emulation instability
- Template drift over time

Mitigation:
- Monthly template rebuild
- Version pinning
- Snapshot backups

---

## 20. Definition of Done

The system is considered production-ready when:

- All Linux containers run headless mode successfully
- Windows 10 installer runs silently
- Web UI reachable on all platforms
- Artifacts collected
- Full matrix executes via single command:

./run_matrix.sh

Without manual intervention.
