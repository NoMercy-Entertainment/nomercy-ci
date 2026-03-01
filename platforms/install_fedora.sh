#!/usr/bin/env bash
# Install NoMercy MediaServer on Fedora via .rpm package
# Usage: install_fedora.sh <release_tag>
# This script runs INSIDE the LXC container via SSH.

set -euo pipefail

RELEASE_TAG="${1:?Usage: $0 <release_tag>}"
VERSION="${RELEASE_TAG#v}"
VERSION="${VERSION%%-*}"
RELEASES_BASE="https://github.com/NoMercy-Entertainment/NoMercyMediaServer/releases/download"
RPM_URL="${RELEASES_BASE}/${RELEASE_TAG}/nomercymediaserver-${VERSION}-1.x86_64.rpm"

echo "=== NoMercy Fedora Install ===" | tee /tmp/install.log
echo "Tag: ${RELEASE_TAG}  Version: ${VERSION}" | tee -a /tmp/install.log
echo "URL: ${RPM_URL}" | tee -a /tmp/install.log

echo "--- Downloading .rpm ---" | tee -a /tmp/install.log
curl -fL "$RPM_URL" -o /tmp/nomercy.rpm 2>&1 | tee -a /tmp/install.log

echo "--- Installing .rpm ---" | tee -a /tmp/install.log
dnf install -y /tmp/nomercy.rpm 2>&1 | tee -a /tmp/install.log

echo "--- Starting service ---" | tee -a /tmp/install.log
systemctl daemon-reload
systemctl enable nomercymediaserver 2>&1 | tee -a /tmp/install.log
systemctl start nomercymediaserver 2>&1 | tee -a /tmp/install.log

echo "--- Done ---" | tee -a /tmp/install.log
