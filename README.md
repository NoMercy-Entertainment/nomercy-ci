# nomercy-ci

A self-hosted, zero-cost CI/CD test lab that automatically validates [NoMercy MediaServer](https://github.com/NoMercy-Entertainment/nomercy-media-server) release binaries across multiple operating systems and architectures. Runs entirely on a single Proxmox VE host using LXC containers and KVM virtual machines — no paid CI services required.

## How It Works

When a new release is published on GitHub, a webhook triggers the test matrix. For each supported platform, an ephemeral clone is created from a pre-built template, the release binary is installed and started, and the web UI endpoint is health-checked. Logs are collected, results are recorded, and the clone is destroyed. Everything is automated and self-cleaning.

```
GitHub Release → Webhook → run_matrix.sh → Clone templates → Install & verify → Collect logs → Destroy clones
```

## Supported Platforms

| Platform | Type | Package Format |
|---|---|---|
| Ubuntu 24.04 LTS | LXC container | `.deb` |
| Debian 13 (Trixie) | LXC container | `.deb` |
| Fedora 43 | LXC container | `.rpm` |
| Arch Linux (rolling) | LXC container | `.pkg.tar.zst` |
| Windows 10 Pro | KVM VM | `.exe` |
| Windows 11 Pro | KVM VM | `.exe` |

Linux targets run **in parallel**. Windows VMs run sequentially due to their higher resource requirements.

## Infrastructure

- **Proxmox VE** (community/no-subscription) — hypervisor with KVM + LXC
- **TrueNAS** (NFS) — artifact and log storage
- **1TB SSD RAID10** — active containers, VMs, and templates

No external CI services, runners, or cloud resources are used.

## Project Structure

```
├── config.sh                  # Central configuration (node name, ports, resource limits, etc.)
├── run_matrix.sh              # Main orchestrator — runs the full test matrix
├── lib/
│   ├── util.sh                # Logging, SSH wait, VMID allocation, retry helpers
│   ├── lxc.sh                 # LXC container lifecycle (clone, get IP, destroy)
│   ├── vm.sh                  # KVM VM lifecycle (clone, get IP via guest agent, destroy)
│   ├── verify.sh              # HTTP/HTTPS health check for the web endpoint
│   └── logs.sh                # Artifact collection from containers and VMs
├── platforms/
│   ├── install_ubuntu.sh      # Ubuntu .deb install script
│   ├── install_debian.sh      # Debian .deb install script
│   ├── install_fedora.sh      # Fedora .rpm install script
│   ├── install_arch.sh        # Arch .pkg.tar.zst install script
│   └── install_windows.ps1    # Windows .exe download and launch script
├── setup/
│   ├── setup_proxmox_host.sh  # One-time Proxmox host bootstrap
│   ├── setup_templates.sh     # Creates Linux LXC base templates
│   ├── setup_windows_template.sh  # Fully automated Windows VM template creation
│   ├── setup_windows_postinstall.ps1  # Windows post-install (VirtIO, SSH, firewall, sysprep)
│   ├── autounattend_win10.xml # Windows 10 unattended install answer file
│   └── autounattend_win11.xml # Windows 11 unattended install answer file
└── webhook/
    ├── webhook_server.py      # Python HTTP server for GitHub release webhooks
    ├── webhook_server.env     # Environment config (secret, ports, paths)
    └── nomercy-ci.service     # systemd unit file for the webhook server
```

## Setup

### Prerequisites

- A Proxmox VE host (community edition)
- A TrueNAS NFS share (or any NFS-capable storage)
- Windows 10/11 ISO files and the [VirtIO drivers ISO](https://fedorapeople.org/groups/virt/virtio-win/direct-downloads/)

### 1. Bootstrap the Proxmox Host

```bash
TRUENAS_IP=<your-truenas-ip> ./setup/setup_proxmox_host.sh
```

This configures repos, installs dependencies, generates SSH keys, mounts the NFS share, and deploys the CI scripts to `/opt/nomercy-ci/`.

### 2. Create Linux Templates

```bash
./setup/setup_templates.sh
```

Downloads official container images and creates hardened LXC templates for each distro with a `ci` user and SSH key auth.

### 3. Create Windows Templates

```bash
# Both Windows 10 and 11
./setup/setup_windows_template.sh

# Or target a specific version
./setup/setup_windows_template.sh win10
./setup/setup_windows_template.sh win11
```

Builds UEFI-based KVM templates with VirtIO drivers, OpenSSH server, and sysprep generalization — fully unattended.

### 4. Configure the Webhook (optional)

Set your GitHub webhook secret in `webhook/webhook_server.env`, then:

```bash
systemctl enable --now nomercy-ci.service
```

Point a GitHub webhook at `http://<proxmox-ip>:9000/webhook` with the `release` event.

## Usage

### Manual Run

```bash
# Test the latest release
./run_matrix.sh

# Test a specific release tag
./run_matrix.sh v1.2.3
```

### Automatic (Webhook)

Publishing a release on GitHub triggers the test matrix automatically. Results are logged to `/mnt/vault/nomercy-artifacts/<tag>/`.

### Artifacts

Each run produces a timestamped directory with:

```
/mnt/vault/nomercy-artifacts/<tag>/<YYYYMMDD_HHMMSS>/
├── ci.log              # Master run log
├── results.txt         # DISTRO:PASS/FAIL summary
├── <distro>-install.log
├── <distro>-journal.log
├── <distro>-sysinfo.txt
├── windows-install.log
├── windows-server.log
├── windows-events.log
└── windows-sysinfo.txt
```

## Configuration

All tunables are in `config.sh`:

| Variable | Default | Description |
|---|---|---|
| `PVE_NODE` | `pve` | Proxmox node name |
| `WEB_PORT` | `7626` | NoMercy web UI port |
| `LXC_CORES` / `LXC_MEM` | `2` / `2048` MB | Linux container resources |
| `WIN_CORES` / `WIN_MEM` | `12` / `16384` MB | Windows VM resources |
| `WEBHOOK_PORT` | `9000` | Webhook listener port |
| `ARTIFACT_ROOT` | `/mnt/vault/nomercy-artifacts` | NFS artifact path |

## Design Principles

- **Ephemeral everything** — every test clone is created, used once, and destroyed. Templates are never modified during runs.
- **Self-cleaning** — `trap cleanup EXIT` ensures all resources are purged even on script failure.
- **Zero cost** — Proxmox Community Edition and open-source tooling only.
- **Security-conscious** — dedicated `ci` user, SSH key-only auth, no root SSH, unprivileged LXC containers.

## License

Copyright NoMercy Entertainment. All rights reserved.
