#!/usr/bin/env bash
# Install NoMercy MediaServer on Fedora via .rpm package
# Usage: install_fedora.sh <release_tag>
# This script runs INSIDE the LXC container via SSH.

set -euo pipefail

RELEASE_TAG="${1:?Usage: $0 <release_tag>}"
VERSION="${RELEASE_TAG#v}"
VERSION="${VERSION%%-*}"
RELEASES_BASE="https://github.com/NoMercy-Entertainment/nomercy-media-server/releases/download"
RPM_URL="${RELEASES_BASE}/${RELEASE_TAG}/nomercymediaserver-${VERSION}-1.x86_64.rpm"

echo "=== NoMercy Fedora Install ===" | tee /tmp/install.log
echo "Tag: ${RELEASE_TAG}  Version: ${VERSION}" | tee -a /tmp/install.log
echo "URL: ${RPM_URL}" | tee -a /tmp/install.log

echo "--- Downloading .rpm ---" | tee -a /tmp/install.log
curl -fL "$RPM_URL" -o /tmp/nomercy.rpm 2>&1 | tee -a /tmp/install.log

echo "--- Installing .rpm ---" | tee -a /tmp/install.log
dnf install -y /tmp/nomercy.rpm 2>&1 | tee -a /tmp/install.log

echo "--- Starting service ---" | tee -a /tmp/install.log
# Resolve the target user that will own the systemd user unit.
# Packages ship a user unit; systemctl --user must run as that user, not root.
if id -u nomercy &>/dev/null; then
    TARGET_USER="nomercy"
elif [ -n "${SUDO_USER:-}" ]; then
    TARGET_USER="$SUDO_USER"
else
    echo "ERROR: cannot determine target user (no 'nomercy' user and SUDO_USER is unset)" | tee -a /tmp/install.log
    exit 1
fi
echo "Target user: ${TARGET_USER}" | tee -a /tmp/install.log
loginctl enable-linger "$TARGET_USER"
su -l "$TARGET_USER" -c 'systemctl --user daemon-reload' 2>&1 | tee -a /tmp/install.log
su -l "$TARGET_USER" -c 'systemctl --user enable nomercymediaserver' 2>&1 | tee -a /tmp/install.log
su -l "$TARGET_USER" -c 'systemctl --user start nomercymediaserver' 2>&1 | tee -a /tmp/install.log

echo "--- Done ---" | tee -a /tmp/install.log
