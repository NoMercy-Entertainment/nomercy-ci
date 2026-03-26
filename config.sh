#!/usr/bin/env bash
# Central configuration for NoMercy CI
# Source this file from all other scripts: source "$(dirname "${BASH_SOURCE[0]}")/config.sh"

# Load .env if it exists
_CI_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -f "${_CI_DIR}/.env" ]]; then
    set -a
    source "${_CI_DIR}/.env"
    set +a
fi

# Proxmox node name
PVE_NODE="pve"

# Artifact storage (NFS mount from TrueNAS)
ARTIFACT_ROOT="/mnt/vault/nomercy-artifacts"

# GitHub repository
GITHUB_ORG="NoMercy-Entertainment"
GITHUB_REPO="nomercy-media-server"
GITHUB_API="https://api.github.com/repos/${GITHUB_ORG}/${GITHUB_REPO}"
GITHUB_RELEASES_BASE="https://github.com/${GITHUB_ORG}/${GITHUB_REPO}/releases/download"

# SSH configuration
SSH_USER="ci"
SSH_KEY="/opt/nomercy-ci/.ssh/ci_ed25519"
SSH_TIMEOUT=120
SSH_OPTS="-o StrictHostKeyChecking=no -o ConnectTimeout=5 -o BatchMode=yes -i ${SSH_KEY}"

# Application port (NoMercy MediaServer default)
WEB_PORT=7626

# LXC Templates — CTIDs of Proxmox LXC templates
# Run setup/setup_templates.sh to create these
declare -A LXC_TEMPLATES=(
    ["ubuntu"]=2000
    ["debian"]=2001
    ["fedora"]=2002
    ["arch"]=2003
)

# Windows KVM template VMIDs
# Run setup/setup_windows_template.sh to create these
declare -A WIN_TEMPLATES=(
    ["win10"]=3000
    ["win11"]=3001
)

# Windows ISO filenames (on nas storage)
declare -A WIN_ISOS=(
    ["win10"]="nas:iso/Windows.10.X64.NL.iso"
    ["win11"]="nas:iso/Win11_25H2_EnglishInternational_x64.iso"
)

# ID range for ephemeral test containers/VMs
LXC_ID_MIN=4000
LXC_ID_MAX=4999
VM_ID_MIN=6000
VM_ID_MAX=6999

# Resource limits — Linux LXC
LXC_CORES=2
LXC_MEM=2048   # MB

# Resource limits — Windows VM
WIN_CORES=12
WIN_MEM=16384    # MB (max)
WIN_BALLOON=4096 # MB (min, ballooning returns unused RAM to host)

# Webhook server port (used by webhook/webhook_server.py)
WEBHOOK_PORT=9000

# ── GitHub Actions Self-Hosted Runners ──────────────────────────────────────

# GitHub PAT with admin:org scope (for runner registration)
# All runner settings come from .env — no hardcoded defaults
RUNNER_GH_TOKEN="${RUNNER_GH_TOKEN:-}"
RUNNER_ORG="${RUNNER_ORG:-}"
RUNNER_GROUP="${RUNNER_GROUP:-}"
RUNNER_VERSION="${RUNNER_VERSION:-}"

# Runner VM template IDs (created by setup/setup_runner_templates.sh)
declare -A RUNNER_TEMPLATES=(
    ["linux"]="${RUNNER_TEMPLATE_LINUX:-5000}"
    ["macos"]="${RUNNER_TEMPLATE_MACOS:-5001}"
    ["windows"]="${RUNNER_TEMPLATE_WINDOWS:-5002}"
)

# Runner VM ID range (ephemeral runners cloned from templates)
RUNNER_ID_MIN="${RUNNER_ID_MIN:-5100}"
RUNNER_ID_MAX="${RUNNER_ID_MAX:-5199}"

# Runner resource limits per OS
RUNNER_LINUX_CORES="${RUNNER_LINUX_CORES:-4}"
RUNNER_LINUX_MEM="${RUNNER_LINUX_MEM:-8192}"

RUNNER_MACOS_CORES="${RUNNER_MACOS_CORES:-4}"
RUNNER_MACOS_MEM="${RUNNER_MACOS_MEM:-8192}"

RUNNER_WINDOWS_CORES="${RUNNER_WINDOWS_CORES:-4}"
RUNNER_WINDOWS_MEM="${RUNNER_WINDOWS_MEM:-8192}"

# Runner labels per OS
RUNNER_LINUX_LABELS="${RUNNER_LINUX_LABELS:-}"
RUNNER_MACOS_LABELS="${RUNNER_MACOS_LABELS:-}"
RUNNER_WINDOWS_LABELS="${RUNNER_WINDOWS_LABELS:-}"

# ISOs for runner templates (Linux uses LXC — no image needed)
RUNNER_MACOS_ISO="${RUNNER_MACOS_ISO:-}"
RUNNER_OPENCORE_ISO="${RUNNER_OPENCORE_ISO:-}"
RUNNER_MACOS_VERSION="${RUNNER_MACOS_VERSION:-sonoma}"
RUNNER_WINDOWS_ISO="${RUNNER_WINDOWS_ISO:-}"
