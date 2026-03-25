# nomercy-ci

A self-hosted, zero-cost CI/CD test lab and GitHub Actions runner farm, running entirely on a single Proxmox VE host using LXC containers and KVM virtual machines — no paid CI services required.

## What This Does

Two things:

1. **Test matrix** — Automatically validates [NoMercy MediaServer](https://github.com/NoMercy-Entertainment/nomercy-media-server) release binaries across Linux distros and Windows.
2. **GitHub Actions runners** — Provisions self-hosted runners as Proxmox VMs with the full GitHub-hosted runner toolchain (Linux, macOS, Windows).

## Quick Start — Runners

### 1. Configure

```bash
cp .env.example .env
# Edit .env — fill in RUNNER_GH_TOKEN and review all settings
```

### 2. Create templates (one-time per OS)

```bash
# Linux — fully automated (cloud-init + SSH + tool install)
./runners/setup_runner_templates.sh linux

# macOS — creates VM shell, manual OS install required (see output for steps)
./runners/setup_runner_templates.sh macos

# Windows — fully automated (unattended install + sysprep, ~20-40 min)
./runners/setup_runner_templates.sh windows
```

### 3. Spin up runners

```bash
./runners/create_runner.sh linux 5       # 5 Linux runners
./runners/create_runner.sh macos 1       # 1 macOS runner
./runners/create_runner.sh windows 1     # 1 Windows runner
./runners/create_runner.sh all 2         # 2 of each
```

Each runner VM is cloned from the template, booted, and registered with GitHub Actions automatically. They appear in your org's runner list within seconds.

### 4. Tear down

```bash
./runners/destroy_runners.sh all         # destroy all runners + deregister from GitHub
./runners/destroy_runners.sh linux       # just Linux
./runners/destroy_runners.sh --vm 5103   # specific VM
```

### What's installed on the runners

Linux runners mirror GitHub's `ubuntu-24.04` hosted runner:

| Category | Tools |
|---|---|
| Languages | Node 20+22, PHP 8.3+8.4, Java 8/11/17/21/25, .NET 8/9/10, Go 1.24, Ruby, Rust, Python 3 |
| Build tools | CMake 3.31, Ninja, Gradle 8.14, Maven 3.9, Ant |
| Android | SDK platforms 34-36, build-tools 34-36.1, NDK 27/28/29 |
| Containers | Docker CE + Compose + Buildx, Buildah, Podman, Skopeo |
| CLIs | gh, aws v2, azure, kubectl, helm, packer, fastlane |
| Browsers | Chrome + ChromeDriver, Firefox + Geckodriver |
| Databases | PostgreSQL client, MySQL client, SQLite3 |

macOS runners use Homebrew with the same tools. Windows runners use Chocolatey.

---

## Quick Start — Test Matrix

### 1. Bootstrap Proxmox host

```bash
TRUENAS_IP=<your-truenas-ip> ./setup/setup_proxmox_host.sh
```

### 2. Create test templates

```bash
./setup/setup_templates.sh                # Linux LXC templates
./setup/setup_windows_template.sh         # Windows VM templates
```

### 3. Run tests

```bash
./run_matrix.sh                           # test latest release
./run_matrix.sh v1.2.3                    # test specific tag
```

### 4. Webhook (optional)

```bash
systemctl enable --now nomercy-ci.service
```

Point a GitHub webhook at `http://<proxmox-ip>:9000/webhook` with the `release` event.

---

## Project Structure

```
├── config.sh                      # Central config (loads .env)
├── .env.example                   # All settings with defaults
├── run_matrix.sh                  # Test matrix orchestrator
│
├── runners/                       # GitHub Actions runner management
│   ├── setup_runner_templates.sh  # Create Proxmox VM templates per OS
│   ├── create_runner.sh           # Clone template → boot → register with GitHub
│   ├── destroy_runners.sh         # Stop VMs + deregister from GitHub
│   ├── install_linux_runner.sh    # Ubuntu 24.04 tool install (runs inside VM)
│   ├── install_macos_runner.sh    # macOS tool install (Homebrew-based)
│   └── install_windows_runner.ps1 # Windows tool install (Chocolatey-based)
│
├── lib/
│   ├── util.sh                    # Logging, SSH wait, VMID allocation
│   ├── lxc.sh                     # LXC lifecycle (clone, IP, destroy)
│   ├── vm.sh                      # KVM lifecycle (clone, IP via guest agent, destroy)
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
│   ├── setup_templates.sh         # Linux LXC test templates
│   ├── setup_windows_template.sh  # Windows VM test templates
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

All settings come from `.env` (loaded by `config.sh`). Copy `.env.example` and fill in your values.

### Runner settings

| Variable | Description |
|---|---|
| `RUNNER_GH_TOKEN` | GitHub PAT with `admin:org` scope |
| `RUNNER_ORG` | GitHub organization name |
| `RUNNER_GROUP` | Runner group in GitHub |
| `RUNNER_VERSION` | GitHub Actions runner version |
| `RUNNER_LINUX_LABELS` | Comma-separated labels for Linux runners |
| `RUNNER_MACOS_LABELS` | Comma-separated labels for macOS runners |
| `RUNNER_WINDOWS_LABELS` | Comma-separated labels for Windows runners |
| `RUNNER_LINUX_CORES` / `_MEM` | CPU cores and RAM (MB) per Linux runner VM |
| `RUNNER_MACOS_CORES` / `_MEM` | CPU cores and RAM (MB) per macOS runner VM |
| `RUNNER_WINDOWS_CORES` / `_MEM` | CPU cores and RAM (MB) per Windows runner VM |
| `RUNNER_LINUX_IMAGE` | Ubuntu cloud image URL |
| `RUNNER_MACOS_ISO` | macOS ISO on Proxmox storage |
| `RUNNER_WINDOWS_ISO` | Windows ISO on Proxmox storage |

### Test matrix settings

| Variable | Description |
|---|---|
| `PVE_NODE` | Proxmox node name |
| `WEB_PORT` | NoMercy web UI port (default 7626) |
| `LXC_CORES` / `LXC_MEM` | Linux test container resources |
| `WIN_CORES` / `WIN_MEM` | Windows test VM resources |
| `WEBHOOK_PORT` | Webhook listener port (default 9000) |
| `ARTIFACT_ROOT` | NFS path for test artifacts |

## Design Principles

- **Ephemeral everything** — runner VMs and test clones are created, used, and destroyed. Templates are never modified during runs.
- **Self-cleaning** — `trap cleanup EXIT` ensures all resources are purged even on script failure. Runners deregister from GitHub on destroy.
- **Zero cost** — Proxmox Community Edition and open-source tooling only.
- **Security-conscious** — dedicated `ci` user, SSH key-only auth, no root SSH.
- **No Docker for runners** — real VMs, not containers. Full OS isolation, real kernel, no permission hacks.

## License

Copyright NoMercy Entertainment. All rights reserved.
