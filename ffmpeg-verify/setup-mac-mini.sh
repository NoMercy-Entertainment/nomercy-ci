#!/usr/bin/env bash
# Prepares the Mac mini to verify three of the six platforms. Run this ON the
# Mac.
#
# One machine covers darwin-arm64, darwin-x86_64 and linux-aarch64:
#   * darwin-arm64  — native.
#   * darwin-x86_64 — through Rosetta 2. There is no Intel Mac in the fleet, and
#     an emulated one would not be "real hardware" either. The verdict records
#     translation explicitly so the evidence never reads as a native x86 Mac.
#   * linux-aarch64 — a Linux guest under Lima's vz backend. That is real ARM
#     silicon, which qemu-emulating aarch64 on the x86 Proxmox host would not be.
#
# Homebrew is deliberately not required: Lima is installed from its release
# tarball so this needs no package manager and no admin rights beyond the one
# Rosetta install, which Apple gates behind sudo.
set -euo pipefail

LIMA_VERSION="${LIMA_VERSION:-2.2.0}"
LIMA_INSTANCE="${LIMA_INSTANCE:-linux-arm64}"
LIMA_HOME="${LIMA_HOME:-${HOME}/lima}"
LIMA_CPUS="${LIMA_CPUS:-4}"
LIMA_MEMORY="${LIMA_MEMORY:-6}"
LIMA_DISK="${LIMA_DISK:-16}"
RUNNER_NAME="${RUNNER_NAME:-ffmpeg-verify-mac}"
RUNNER_LABELS="${RUNNER_LABELS:-ffmpeg-verify,darwin-arm64,darwin-x86_64,linux-aarch64}"
TOKEN="${RUNNER_TOKEN:-}"

[[ "$(uname -s)" == "Darwin" ]] || {
	echo "Error: run this on the Mac." >&2
	exit 2
}

echo "── Rosetta 2 ──"
if arch -x86_64 /usr/bin/true >/dev/null 2>&1; then
	echo "Already installed."
else
	# The only step here that needs sudo. Without it darwin-x86_64 cannot be
	# executed at all and its checklist box can never legitimately be ticked.
	sudo softwareupdate --install-rosetta --agree-to-license
	arch -x86_64 /usr/bin/true >/dev/null 2>&1 ||
		{ echo "❌ Rosetta still unavailable." >&2; exit 1; }
fi

echo "── Lima ──"
mkdir -p "$LIMA_HOME"
if [[ ! -x "${LIMA_HOME}/bin/limactl" ]]; then
	curl -fsSL -o "${LIMA_HOME}/lima.tar.gz" \
		"https://github.com/lima-vm/lima/releases/download/v${LIMA_VERSION}/lima-${LIMA_VERSION}-Darwin-arm64.tar.gz"
	tar -xzf "${LIMA_HOME}/lima.tar.gz" -C "$LIMA_HOME"
	rm -f "${LIMA_HOME}/lima.tar.gz"
fi
"${LIMA_HOME}/bin/limactl" --version

if "${LIMA_HOME}/bin/limactl" list --format '{{.Name}}' 2>/dev/null | grep -qx "$LIMA_INSTANCE"; then
	echo "Instance ${LIMA_INSTANCE} exists; ensuring it is running."
	"${LIMA_HOME}/bin/limactl" start "$LIMA_INSTANCE" --tty=false 2>/dev/null || true
else
	"${LIMA_HOME}/bin/limactl" start --name="$LIMA_INSTANCE" --vm-type=vz \
		--cpus="$LIMA_CPUS" --memory="$LIMA_MEMORY" --disk="$LIMA_DISK" \
		--tty=false template://ubuntu-24.04
fi

# A guest that reports x86_64 would mean the vz backend silently fell back to
# emulation, and every linux-aarch64 verdict from it would be worthless.
GUEST_ARCH=$("${LIMA_HOME}/bin/limactl" shell "$LIMA_INSTANCE" -- uname -m)
[[ "$GUEST_ARCH" == "aarch64" ]] || {
	echo "❌ Lima guest reports ${GUEST_ARCH}, expected aarch64." >&2
	exit 1
}
echo "Lima guest is ${GUEST_ARCH}."

if [[ -n "$TOKEN" ]]; then
	echo "── Runner ──"
	HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
	bash "${HERE}/install-runner.sh" --name "$RUNNER_NAME" --labels "$RUNNER_LABELS" --token "$TOKEN"
else
	echo "── Runner skipped (set RUNNER_TOKEN to register) ──"
fi

cat <<INFO

✅ Mac mini ready.

Set these repository variables on nomercy-ffmpeg so the workflow can find Lima:
  VERIFY_LIMA_INSTANCE = ${LIMA_INSTANCE}
  VERIFY_LIMA_BIN      = ${LIMA_HOME}/bin/limactl
INFO
