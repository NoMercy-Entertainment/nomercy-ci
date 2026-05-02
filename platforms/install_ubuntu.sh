#!/usr/bin/env bash
# Install NoMercy MediaServer on Ubuntu via .deb package
# Usage: install_ubuntu.sh <release_tag>
# This script runs INSIDE the LXC container via SSH.

set -euo pipefail

RELEASE_TAG="${1:?Usage: $0 <release_tag>}"
VERSION="${RELEASE_TAG#v}"           # strip leading v
VERSION="${VERSION%%-*}"             # strip branch suffix (e.g. 0.1.236)
RELEASES_BASE="https://github.com/NoMercy-Entertainment/nomercy-media-server/releases/download"
DEB_URL="${RELEASES_BASE}/${RELEASE_TAG}/nomercymediaserver_${VERSION}_amd64.deb"

echo "=== NoMercy Ubuntu Install ===" | tee /tmp/install.log
echo "Tag: ${RELEASE_TAG}  Version: ${VERSION}" | tee -a /tmp/install.log
echo "URL: ${DEB_URL}" | tee -a /tmp/install.log

echo "--- Downloading .deb ---" | tee -a /tmp/install.log
curl -fL "$DEB_URL" -o /tmp/nomercy.deb 2>&1 | tee -a /tmp/install.log

echo "--- Installing .deb ---" | tee -a /tmp/install.log
DEBIAN_FRONTEND=noninteractive dpkg -i /tmp/nomercy.deb 2>&1 | tee -a /tmp/install.log || true
DEBIAN_FRONTEND=noninteractive apt-get install -f -y 2>&1 | tee -a /tmp/install.log

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
