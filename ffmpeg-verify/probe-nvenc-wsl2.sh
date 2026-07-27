#!/usr/bin/env bash
# Reproduces the WSL2 NVENC failure in the nomercy-ffmpeg static build, and
# shows that a dynamically linked ffmpeg on the same machine succeeds.
#
# Run inside a WSL2 distro on a host with an NVIDIA GPU:
#   wsl -d Ubuntu-24.04 -- bash probe-nvenc-wsl2.sh [rc-tag]
#
# Why this exists: WSL2 exposes the GPU through /dev/dxg, and its
# /usr/lib/wsl/lib/libcuda.so.1 is a SHIM that dlopens the real driver from
# /usr/lib/wsl/drivers/... A statically linked binary cannot complete that
# second-stage load, so cuInit returns CUDA_ERROR_OPERATING_SYSTEM even though
# nvidia-smi works and libnvidia-encode resolves fine.
#
# This is why Linux NVENC is unverifiable on the Windows host: the passthrough
# is fine, the build is what cannot use it.
set -uo pipefail

TAG="${1:-v1.0.39-rc}"
WORK="${HOME}/nvenc-wsl2-probe"
BASE="https://github.com/NoMercy-Entertainment/nomercy-ffmpeg/releases/download/${TAG}"
ARCHIVE="ffmpeg-8.1.2-linux-x86_64-${TAG}.tar.gz"

mkdir -p "$WORK" && cd "$WORK"

echo "── environment ──"
printf 'dxg          : %s\n' "$(test -e /dev/dxg && echo present || echo MISSING)"
printf 'nvidia-smi   : %s\n' "$(nvidia-smi --query-gpu=name,driver_version --format=csv,noheader 2>/dev/null | head -1)"
printf 'libcuda      : %s\n' "$(ldconfig -p | grep -m1 'libcuda\.so\.1' | sed 's/.*=> //')"
printf 'libnvidia-enc: %s\n' "$(ldconfig -p | grep -m1 'libnvidia-encode\.so\.1' | sed 's/.*=> //')"

if [[ ! -f "${WORK}/ffmpeg" ]]; then
	echo "── downloading ${TAG} ──"
	curl -fsSL -o f.tar.gz "${BASE}/${ARCHIVE}" || { echo "download failed"; exit 1; }
	tar -xzf f.tar.gz && rm -f f.tar.gz
fi
chmod +x ffmpeg

encode() { # binary, label, output
	local bin="$1" label="$2" out="$3"
	"$bin" -hide_banner -y -f lavfi -i "testsrc=duration=1:size=640x480:rate=30" \
		-c:v h264_nvenc "$out" >"${label}.log" 2>&1
	local code=$?
	local size=0
	[[ -f "$out" ]] && size=$(stat -c%s "$out" 2>/dev/null || echo 0)
	printf '%-22s exit=%-3s bytes=%-8s %s\n' "$label" "$code" "$size" \
		"$([[ $code -eq 0 && $size -gt 0 ]] && echo OK || echo FAILED)"
	grep -m1 -iE 'cuInit|CUDA_ERROR' "${label}.log" | sed 's/^/    /'
}

echo
echo "── linkage ──"
printf 'fork  : %s\n' "$(file ./ffmpeg | grep -o 'statically linked\|dynamically linked')"
if [[ -x /usr/bin/ffmpeg ]]; then
	printf 'stock : %s\n' "$(file /usr/bin/ffmpeg | grep -o 'statically linked\|dynamically linked')"
fi

echo
echo "── NVENC ──"
encode ./ffmpeg "fork-static" "$WORK/fork.mp4"

# Counted rather than `grep -q`: under pipefail, grep -q exits on first match,
# ffmpeg takes SIGPIPE, and the pipeline reports failure despite the match —
# which silently skipped the comparison this script exists to make.
stock_nvenc=0
if [[ -x /usr/bin/ffmpeg ]]; then
	stock_nvenc=$(/usr/bin/ffmpeg -hide_banner -encoders 2>/dev/null | grep -c h264_nvenc || true)
fi
if [[ "${stock_nvenc:-0}" -gt 0 ]]; then
	encode /usr/bin/ffmpeg "stock-dynamic" "$WORK/stock.mp4"
else
	echo "stock-dynamic          skipped — no system ffmpeg with nvenc (apt install ffmpeg)"
fi

echo
echo "If the fork fails while stock succeeds, the GPU passthrough is fine and the"
echo "static link is the cause."
