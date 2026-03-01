#!/usr/bin/env bash
# Central configuration for NoMercy CI
# Source this file from all other scripts: source "$(dirname "${BASH_SOURCE[0]}")/config.sh"

# Proxmox node name
PVE_NODE="pve"

# Artifact storage (NFS mount from TrueNAS)
ARTIFACT_ROOT="/mnt/vault/nomercy-artifacts"

# GitHub repository
GITHUB_ORG="NoMercy-Entertainment"
GITHUB_REPO="NoMercyMediaServer"
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
