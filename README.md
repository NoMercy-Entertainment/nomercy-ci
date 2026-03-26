# nomercy-ci

A self-hosted, zero-cost CI/CD test lab and GitHub Actions runner farm, running entirely on a single Proxmox VE host using LXC containers and KVM virtual machines.

## Runners

Ephemeral self-hosted GitHub Actions runners. Fresh environment every job — identical to GitHub-hosted runners.

### Setup

```bash
# 1. Configure
cp .env.example .env
# Edit .env — fill in RUNNER_GH_TOKEN and review all settings

# 2. Create templates
./runners/setup_runner_templates.sh linux     # LXC — fully automated (~15 min)
./runners/setup_runner_templates.sh macos     # VM — downloads from Apple, manual install from console
./runners/setup_runner_templates.sh windows   # VM — unattended install (~30 min)

# 3. Start the runner pool (maintains N runners, recycles after each job)
./runners/runner_pool.sh all >> /var/log/nomercy-runners/pool.log 2>&1 & disown

# Or install as a service
cp runners/nomercy-runner-pool.service /etc/systemd/system/
systemctl daemon-reload
systemctl enable --now nomercy-runner-pool
```

### How it works

```
Pool manager starts
  ├── Slot 1: Clone LXC → Boot → Register (--ephemeral) → Run job → Destroy → Repeat
  ├── Slot 2: Clone LXC → Boot → Register (--ephemeral) → Run job → Destroy → Repeat
  ├── ...
  └── Slot N: Same cycle
```

Each runner picks up one job, runs it, auto-deregisters, gets destroyed, and the pool spawns a replacement. Clean state every job.

### Runner types

| OS | Type | Template setup | Install |
|---|---|---|---|
| Linux | LXC container | Fully automated (Ubuntu 24.04 LXC + all CI tools via SSH) | ~15 min |
| macOS | KVM VM | Downloads recovery from Apple CDN + OpenCore bootloader. Manual OS install from Proxmox console | ~30 min |
| Windows | KVM VM | Unattended install via autounattend XML + sysprep | ~30 min |

### What's installed on Linux runners

Mirrors GitHub's `ubuntu-24.04` hosted runner:

| Category | Tools |
|---|---|
| Languages | Node 20+22, PHP 8.3+8.4, Java 8/11/17/21/25, .NET 8/9/10, Go 1.24, Ruby, Rust, Python 3 |
| Build tools | CMake 3.31, Ninja, Gradle 8.14, Maven 3.9, Ant |
| Android | SDK platforms 34-36, build-tools 34-36.1, NDK 27/28/29 |
| Containers | Docker CE + Compose + Buildx |
| CLIs | gh, aws v2, azure, kubectl, helm, packer, fastlane |
| Browsers | Chrome + ChromeDriver, Firefox + Geckodriver |
| Databases | PostgreSQL client, MySQL client, SQLite3 |

### Commands

```bash
# Create templates (one-time)
./runners/setup_runner_templates.sh linux
./runners/setup_runner_templates.sh macos
./runners/setup_runner_templates.sh windows
./runners/setup_runner_templates.sh all

# Start runner pool (ephemeral — fresh clone every job)
./runners/runner_pool.sh all                  # all OS types, reads counts from .env
./runners/runner_pool.sh linux 5              # 5 Linux runners only

# Create persistent runners (non-ephemeral)
./runners/create_runner.sh linux 5
./runners/create_runner.sh macos 1
./runners/create_runner.sh windows 1
./runners/create_runner.sh all 2

# Destroy runners + deregister from GitHub
./runners/destroy_runners.sh all
./runners/destroy_runners.sh linux
./runners/destroy_runners.sh --vm 5103

# Resource usage overview
./runners/proxmox-usage.sh
```

### macOS setup notes

macOS in a VM requires OpenCore as the bootloader. The script handles this automatically:

1. Downloads OpenCore v21 from [thenickdude/KVM-Opencore](https://github.com/thenickdude/KVM-Opencore)
2. Downloads macOS recovery from Apple CDN (version configurable via `RUNNER_MACOS_VERSION`)
3. Imports both as disk images (not CD-ROMs)
4. Configures Apple SMC passthrough + CPU flags
5. All disks on SATA (macOS has no VirtIO SCSI drivers)

After the script creates the VM, open the Proxmox console to complete the install:

1. OpenCore boot picker appears — select the macOS installer
2. Open Disk Utility — erase the ~50 GB SATA disk as APFS
3. Install macOS to that disk
4. VM reboots — select "macOS Installer" in OpenCore (continues install)
5. After final reboot — select "Macintosh HD" in OpenCore
6. Enable SSH: System Settings > General > Sharing > Remote Login
7. Create user, install SSH key, run `install_macos_runner.sh`
8. Shut down and convert to template: `qm stop <vmid> && qm set <vmid> --template 1`

---

## Test Matrix

Validates NoMercy MediaServer release binaries across Linux distros and Windows.

### Setup

```bash
# 1. Bootstrap Proxmox host
TRUENAS_IP=<your-truenas-ip> ./setup/setup_proxmox_host.sh

# 2. Create test templates
./setup/setup_templates.sh                # Linux LXC templates
./setup/setup_windows_template.sh         # Windows VM templates

# 3. Run tests
./run_matrix.sh                           # test latest release
./run_matrix.sh v1.2.3                    # test specific tag

# 4. Webhook (optional)
cp webhook/nomercy-ci.service /etc/systemd/system/
systemctl enable --now nomercy-ci
# Point GitHub webhook at http://<proxmox-ip>:9000/webhook (release event)
```

### Supported platforms

| Platform | Type | Package |
|---|---|---|
| Ubuntu 24.04 | LXC | `.deb` |
| Debian 13 | LXC | `.deb` |
| Fedora 43 | LXC | `.rpm` |
| Arch Linux | LXC | `.pkg.tar.zst` |
| Windows 10 | KVM VM | `.exe` |

Linux targets run in parallel. Windows runs sequentially.

---

## Project Structure

```
├── config.sh                      # Central config (loads .env)
├── .env.example                   # All settings with defaults
├── run_matrix.sh                  # Test matrix orchestrator
│
├── runners/                       # GitHub Actions runner management
│   ├── setup_runner_templates.sh  # Create Proxmox templates per OS
│   ├── runner_pool.sh             # Ephemeral runner pool manager
│   ├── create_runner.sh           # Create persistent runners
│   ├── destroy_runners.sh         # Destroy runners + deregister
│   ├── proxmox-usage.sh           # Resource usage overview
│   ├── nomercy-runner-pool.service # systemd service for pool
│   ├── install_linux_runner.sh    # Ubuntu 24.04 tool install
│   ├── install_macos_runner.sh    # macOS tool install (Homebrew)
│   └── install_windows_runner.ps1 # Windows tool install (Chocolatey)
│
├── lib/
│   ├── util.sh                    # Logging, SSH wait, VMID allocation
│   ├── lxc.sh                     # LXC lifecycle
│   ├── vm.sh                      # KVM lifecycle
│   ├── verify.sh                  # HTTP health checks
│   └── logs.sh                    # Artifact collection
│
├── platforms/                     # MediaServer install scripts per distro
│   ├── install_ubuntu.sh
│   ├── install_debian.sh
│   ├── install_fedora.sh
│   ├── install_arch.sh
│   └── install_windows.ps1
│
├── setup/                         # One-time Proxmox setup
│   ├── setup_proxmox_host.sh
│   ├── setup_templates.sh
│   ├── setup_windows_template.sh
│   ├── setup_windows_postinstall.ps1
│   ├── autounattend_win10.xml
│   └── autounattend_win11.xml
│
└── webhook/
    ├── webhook_server.py
    ├── webhook_server.env
    └── nomercy-ci.service
```

## Configuration

All settings in `.env` (loaded by `config.sh`).

### Runner settings

| Variable | Default | Description |
|---|---|---|
| `RUNNER_GH_TOKEN` | — | GitHub PAT with `admin:org` scope |
| `RUNNER_ORG` | — | GitHub organization |
| `RUNNER_GROUP` | `Default` | Runner group in GitHub |
| `RUNNER_VERSION` | — | GitHub Actions runner version |
| `POOL_LINUX` | `5` | Ephemeral Linux runner count |
| `POOL_MACOS` | `1` | Ephemeral macOS runner count |
| `POOL_WINDOWS` | `1` | Ephemeral Windows runner count |
| `RUNNER_LINUX_LABELS` | — | Comma-separated labels |
| `RUNNER_MACOS_LABELS` | — | Comma-separated labels |
| `RUNNER_WINDOWS_LABELS` | — | Comma-separated labels |
| `RUNNER_LINUX_CORES` / `_MEM` | `4` / `8192` | Resources per Linux runner |
| `RUNNER_MACOS_CORES` / `_MEM` | `4` / `8192` | Resources per macOS runner |
| `RUNNER_WINDOWS_CORES` / `_MEM` | `4` / `8192` | Resources per Windows runner |
| `RUNNER_OPENCORE_ISO` | — | OpenCore ISO on Proxmox storage |
| `RUNNER_MACOS_VERSION` | `sonoma` | macOS version to download from Apple |
| `RUNNER_WINDOWS_ISO` | — | Windows ISO on Proxmox storage |

### Test matrix settings

| Variable | Default | Description |
|---|---|---|
| `PVE_NODE` | `pve` | Proxmox node name |
| `WEB_PORT` | `7626` | NoMercy web UI port |
| `LXC_CORES` / `LXC_MEM` | `2` / `2048` | Linux test container resources |
| `WIN_CORES` / `WIN_MEM` | `12` / `16384` | Windows test VM resources |
| `WEBHOOK_PORT` | `9000` | Webhook listener port |
| `ARTIFACT_ROOT` | `/mnt/vault/nomercy-artifacts` | NFS artifact path |

## Design Principles

- **Ephemeral everything** — runners and test clones are created, used once, and destroyed
- **Self-cleaning** — `trap cleanup EXIT` purges resources on failure
- **Zero cost** — Proxmox Community Edition, no paid CI services
- **Security-conscious** — dedicated `ci` user, SSH key-only auth, no root SSH
- **No Docker for runners** — real LXC containers and VMs, full OS isolation

## License

Copyright NoMercy Entertainment. All rights reserved.
