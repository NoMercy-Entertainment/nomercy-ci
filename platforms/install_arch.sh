#!/usr/bin/env bash
# Install NoMercy MediaServer on Arch Linux via .pkg.tar.zst
# Usage: install_arch.sh <release_tag>
# This script runs INSIDE the LXC container via SSH.

set -euo pipefail

RELEASE_TAG="${1:?Usage: $0 <release_tag>}"
VERSION="${RELEASE_TAG#v}"
VERSION="${VERSION%%-*}"
RELEASES_BASE="https://github.com/NoMercy-Entertainment/NoMercyMediaServer/releases/download"
PKG_URL="${RELEASES_BASE}/${RELEASE_TAG}/nomercymediaserver-${VERSION}-1-x86_64.pkg.tar.zst"

echo "=== NoMercy Arch Linux Install ===" | tee /tmp/install.log
echo "Tag: ${RELEASE_TAG}  Version: ${VERSION}" | tee -a /tmp/install.log
echo "URL: ${PKG_URL}" | tee -a /tmp/install.log

echo "--- Downloading .pkg.tar.zst ---" | tee -a /tmp/install.log
curl -fL "$PKG_URL" -o /tmp/nomercy.pkg.tar.zst 2>&1 | tee -a /tmp/install.log

echo "--- Installing package ---" | tee -a /tmp/install.log
# --noconfirm skips interactive prompts; -U installs a local package file
pacman -U --noconfirm /tmp/nomercy.pkg.tar.zst 2>&1 | tee -a /tmp/install.log

echo "--- Starting service ---" | tee -a /tmp/install.log
systemctl daemon-reload
systemctl enable nomercymediaserver 2>&1 | tee -a /tmp/install.log
systemctl start nomercymediaserver 2>&1 | tee -a /tmp/install.log

echo "--- Done ---" | tee -a /tmp/install.log
