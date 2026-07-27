#!/usr/bin/env bash
# Creates the LXC container that verifies linux-x86_64 and drives the FreeBSD
# guest over SSH. Run this ON the Proxmox host.
#
# Idempotent: re-running against an existing container reconfigures it rather
# than failing, so this doubles as the repair path when a runner goes bad.
set -euo pipefail

CTID="${CTID:-5200}"
HOSTNAME="${HOSTNAME_:-ffmpeg-verify-linux}"
TEMPLATE="${TEMPLATE:-local:vztmpl/ubuntu-24.04-standard_24.04-2_amd64.tar.zst}"
STORAGE="${STORAGE:-local-lvm}"
BRIDGE="${BRIDGE:-vmbr0}"
CORES="${CORES:-8}"
MEMORY="${MEMORY:-16384}"
DISK="${DISK:-32}"
LABELS="${LABELS:-ffmpeg-verify,linux-x86_64,freebsd-driver}"
RUNNER_NAME="${RUNNER_NAME:-ffmpeg-verify-linux}"
TOKEN="${RUNNER_TOKEN:-}"

[[ -n "$TOKEN" ]] || {
	echo "Error: RUNNER_TOKEN is required." >&2
	echo "  gh api -X POST orgs/NoMercy-Entertainment/actions/runners/registration-token --jq .token" >&2
	exit 2
}

if pct status "$CTID" >/dev/null 2>&1; then
	echo "CT ${CTID} exists — reusing it."
	pct unlock "$CTID" 2>/dev/null || true
	pct start "$CTID" 2>/dev/null || true
else
	echo "Creating CT ${CTID}…"
	pct create "$CTID" "$TEMPLATE" \
		--hostname "$HOSTNAME" \
		--cores "$CORES" --memory "$MEMORY" --swap 2048 \
		--rootfs "${STORAGE}:${DISK}" \
		--net0 "name=eth0,bridge=${BRIDGE},ip=dhcp" \
		--features nesting=1,keyctl=1 \
		--unprivileged 1 --onboot 1 --start 1
fi

# Give the container a moment to finish bringing up networking before apt.
for _ in $(seq 1 30); do
	pct exec "$CTID" -- getent hosts github.com >/dev/null 2>&1 && break
	sleep 2
done

echo "Installing base tooling…"
pct exec "$CTID" -- bash -c '
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq
  apt-get install -y -qq curl tar unzip jq git ca-certificates sudo openssh-client python3 >/dev/null
'

# The driver reaches the FreeBSD guest with this key. Generated inside the
# container so the private half never leaves it.
echo "Ensuring the FreeBSD driver key exists…"
pct exec "$CTID" -- bash -c '
  id -u runner >/dev/null 2>&1 || useradd -m -s /bin/bash runner
  su - runner -c "test -f ~/.ssh/id_ed25519 || ssh-keygen -t ed25519 -N \"\" -f ~/.ssh/id_ed25519 -C ffmpeg-verify-driver >/dev/null"
'
echo "Driver public key (authorise this on the FreeBSD guest):"
pct exec "$CTID" -- su - runner -c 'cat ~/.ssh/id_ed25519.pub'

echo "Registering the runner…"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
pct push "$CTID" "${HERE}/install-runner.sh" /root/install-runner.sh --perms 755
pct exec "$CTID" -- bash /root/install-runner.sh \
	--name "$RUNNER_NAME" --labels "$LABELS" --token "$TOKEN"

echo "✅ CT ${CTID} ready. IP:"
pct exec "$CTID" -- ip -4 addr show eth0 | grep -oE 'inet [0-9.]+' | awk '{print $2}'
