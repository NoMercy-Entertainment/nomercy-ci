#!/usr/bin/env bash
# Drives the whole verification fleet by hand, the way verify-rc.yml drives it
# automatically, and collects the verdicts in one place.
#
# Why this exists: the workflow fires on workflow_run, and GitHub only fires
# that for workflows present on the DEFAULT branch. So while verify-rc.yml is
# still on dev, it cannot verify the very PR that would put it on master. This
# is the break-glass path out of that, and the same path for any occasion when
# the fleet has to be driven without Actions.
#
# It runs the same tests/verify-rc.sh and verify-rc.ps1 the workflow runs, with
# the same arguments, so the verdicts are comparable rather than a second
# opinion produced a different way.
#
#   ./verify-rc-manually.sh --tag v1.0.39-rc --commit <sha> [--platform NAME]
#
# Verdicts land in ./verdicts/verdict-<platform>.json next to this script.
set -uo pipefail

REPO='NoMercy-Entertainment/nomercy-ffmpeg'
TAG=''
COMMIT=''
ONLY=''
OUT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/verdicts"

# Where each leg lives. Kept here rather than discovered, because a fleet that
# silently verifies five platforms and calls it six is the failure this whole
# system exists to prevent.
PROXMOX='root@192.168.2.100'
PROXMOX_KEY="${PROXMOX_KEY:-$HOME/.ssh/id_ed25519}"
MAC='stoney@192.168.2.63'
MAC_KEY="${MAC_KEY:-$HOME/.ssh/nomercy_lan_ed25519}"
CT_ID=5200
FREEBSD='root@192.168.2.245'
LIMA_INSTANCE="${LIMA_INSTANCE:-linux-arm64}"
LIMA_BIN="${LIMA_BIN:-/Users/stoney/lima/bin/limactl}"

while [ $# -gt 0 ]; do
	case "$1" in
	--tag) TAG="$2"; shift 2 ;;
	--commit) COMMIT="$2"; shift 2 ;;
	--platform) ONLY="$2"; shift 2 ;;
	--out) OUT="$2"; shift 2 ;;
	*) echo "Unknown option: $1" >&2; exit 2 ;;
	esac
done

[ -n "$TAG" ] || { echo "Error: --tag is required." >&2; exit 2; }
[ -n "$COMMIT" ] || { echo "Error: --commit is required." >&2; exit 2; }

SSH_OPTS='-o BatchMode=yes -o StrictHostKeyChecking=no -o ConnectTimeout=10'
mkdir -p "$OUT"

say_() { printf '\n\033[36m── %s\033[0m\n' "$1"; }
ok_() { printf '  \033[32m[ ok ]\033[0m %s\n' "$1"; }
bad_() { printf '  \033[31m[fail]\033[0m %s\n' "$1"; }

# The asset list, resolved once. Every machine fetches by API URL, which works
# the same whether the repository is public or private.
ASSETS="$(gh api "repos/${REPO}/releases/tags/${TAG}" --jq '[.assets[] | {name, url}] | tojson')"
[ -n "$ASSETS" ] || { echo "Error: release ${TAG} has no assets." >&2; exit 1; }

RELEASE_TARGET="$(gh api "repos/${REPO}/releases/tags/${TAG}" --jq '.target_commitish')"
if [ "$RELEASE_TARGET" != "$COMMIT" ]; then
	echo "Refusing: ${TAG} was built from ${RELEASE_TARGET}, not ${COMMIT}." >&2
	echo "Verifying it would produce verdicts for the wrong artifacts, which is the" >&2
	echo "exact failure this fleet exists to make impossible." >&2
	exit 1
fi

TOKEN="$(gh auth token)"

# The body run on every unix leg. Staged as a file rather than an ssh one-liner
# so quoting survives the two or three hops some of these take.
render_unix_script() {
	local platform="$1" ext="$2"
	cat <<SCRIPT
set -euo pipefail
WORK="\${HOME}/rc-verify/${platform}"
rm -rf "\$WORK" && mkdir -p "\$WORK/rc"
cd "\$WORK"

# The suite and its helpers come from the commit under test, not from whatever
# happens to be checked out on the machine.
if [ ! -d repo/.git ]; then
	git clone -q --no-checkout "https://github.com/${REPO}.git" repo
fi
cd repo && git fetch -q origin "${COMMIT}" && git checkout -q "${COMMIT}" && cd ..

ARCHIVE=\$(printf '%s' '${ASSETS}' | python3 -c "import json,sys; print(next((a['name'] for a in json.load(sys.stdin) if '${platform}' in a['name'] and a['name'].endswith('${ext}')),''))")
[ -n "\$ARCHIVE" ] || { echo "no ${platform} archive in ${TAG}"; exit 1; }

for name in "\$ARCHIVE" manifest.json; do
	url=\$(printf '%s' '${ASSETS}' | N="\$name" python3 -c "import json,sys,os; print(next((a['url'] for a in json.load(sys.stdin) if a['name']==os.environ['N']),''))")
	[ -n "\$url" ] || { echo "asset \$name missing from ${TAG}"; exit 1; }
	curl -fsSL -H "Authorization: Bearer ${TOKEN}" -H "Accept: application/octet-stream" "\$url" -o "rc/\$name"
done

bash repo/tests/verify-rc.sh \\
	--archive "rc/\$ARCHIVE" \\
	--manifest rc/manifest.json \\
	--platform "${platform}" \\
	--workdir "\$WORK/run" \\
	--json "\$WORK/verdict-${platform}.json" \\
	--tag "${TAG}" \\
	--commit "${COMMIT}"
SCRIPT
}

run_leg() {
	local platform="$1"
	[ -z "$ONLY" ] || [ "$ONLY" = "$platform" ] || return 0
	say_ "$platform"
	"leg_${platform//-/_}" && ok_ "$platform verdict collected" || bad_ "$platform FAILED"
}

# ── linux-x86_64: the Proxmox container, as the runner user ────────────────
leg_linux_x86_64() {
	render_unix_script linux-x86_64 tar.gz |
		ssh $SSH_OPTS -i "$PROXMOX_KEY" "$PROXMOX" \
			"pct exec ${CT_ID} -- su - runner -c 'cat > /tmp/leg.sh'" || return 1
	ssh $SSH_OPTS -i "$PROXMOX_KEY" "$PROXMOX" \
		"pct exec ${CT_ID} -- su - runner -c 'bash /tmp/leg.sh'" || return 1
	ssh $SSH_OPTS -i "$PROXMOX_KEY" "$PROXMOX" \
		"pct exec ${CT_ID} -- su - runner -c 'cat ~/rc-verify/linux-x86_64/verdict-linux-x86_64.json'" \
		>"${OUT}/verdict-linux-x86_64.json"
}

# ── freebsd-x86_64: driven from that same container over SSH ───────────────
leg_freebsd_x86_64() {
	render_unix_script freebsd-x86_64 tar.gz |
		ssh $SSH_OPTS -i "$PROXMOX_KEY" "$PROXMOX" \
			"pct exec ${CT_ID} -- su - runner -c 'cat > /tmp/fb.sh'" || return 1
	ssh $SSH_OPTS -i "$PROXMOX_KEY" "$PROXMOX" \
		"pct exec ${CT_ID} -- su - runner -c 'ssh ${SSH_OPTS} ${FREEBSD} \"bash -s\" < /tmp/fb.sh'" || return 1
	ssh $SSH_OPTS -i "$PROXMOX_KEY" "$PROXMOX" \
		"pct exec ${CT_ID} -- su - runner -c 'ssh ${SSH_OPTS} ${FREEBSD} cat rc-verify/freebsd-x86_64/verdict-freebsd-x86_64.json'" \
		>"${OUT}/verdict-freebsd-x86_64.json"
}

# ── darwin-arm64 and darwin-x86_64: the Mac, native and under Rosetta ──────
leg_darwin_arm64() { mac_leg darwin-arm64; }
leg_darwin_x86_64() { mac_leg darwin-x86_64; }
mac_leg() {
	local platform="$1"
	render_unix_script "$platform" tar.gz |
		ssh $SSH_OPTS -i "$MAC_KEY" "$MAC" "cat > /tmp/${platform}.sh" || return 1
	ssh $SSH_OPTS -i "$MAC_KEY" "$MAC" "bash /tmp/${platform}.sh" || return 1
	ssh $SSH_OPTS -i "$MAC_KEY" "$MAC" \
		"cat ~/rc-verify/${platform}/verdict-${platform}.json" >"${OUT}/verdict-${platform}.json"
}

# ── linux-aarch64: the Lima guest on that same Mac ─────────────────────────
leg_linux_aarch64() {
	render_unix_script linux-aarch64 tar.gz |
		ssh $SSH_OPTS -i "$MAC_KEY" "$MAC" "cat > /tmp/aarch64.sh" || return 1
	ssh $SSH_OPTS -i "$MAC_KEY" "$MAC" \
		"${LIMA_BIN} shell ${LIMA_INSTANCE} -- bash -s < /tmp/aarch64.sh" || return 1
	ssh $SSH_OPTS -i "$MAC_KEY" "$MAC" \
		"${LIMA_BIN} shell ${LIMA_INSTANCE} -- cat rc-verify/linux-aarch64/verdict-linux-aarch64.json" \
		>"${OUT}/verdict-linux-aarch64.json"
}

# ── windows-x86_64: this machine, where the only NVENC card is ─────────────
# Run locally rather than over SSH: this script is driven from the Windows host,
# which is also the only machine in the fleet with an NVIDIA card. Printing
# instructions here instead of doing the work would leave the one platform
# nothing else can cover as the one platform the driver does not drive.
leg_windows_x86_64() {
	local work="${LOCALAPPDATA:-$HOME}/rc-verify/windows-x86_64"
	rm -rf "$work" && mkdir -p "$work/rc" || return 1

	if [ ! -d "${work}/repo/.git" ]; then
		git clone -q --no-checkout "https://github.com/${REPO}.git" "${work}/repo" || return 1
	fi
	git -C "${work}/repo" fetch -q origin "$COMMIT" && git -C "${work}/repo" checkout -q "$COMMIT" || return 1

	local archive
	archive="$(printf '%s' "$ASSETS" | python3 -c "import json,sys; print(next((a['name'] for a in json.load(sys.stdin) if 'windows-x86_64' in a['name'] and a['name'].endswith('zip')),''))")"
	[ -n "$archive" ] || { echo "  no windows archive in ${TAG}"; return 1; }

	local name url
	for name in "$archive" manifest.json; do
		url="$(printf '%s' "$ASSETS" | N="$name" python3 -c "import json,sys,os; print(next((a['url'] for a in json.load(sys.stdin) if a['name']==os.environ['N']),''))")"
		[ -n "$url" ] || { echo "  asset ${name} missing from ${TAG}"; return 1; }
		curl -fsSL -H "Authorization: Bearer ${TOKEN}" -H 'Accept: application/octet-stream' "$url" -o "${work}/rc/${name}" || return 1
	done

	pwsh -NoProfile -File "${work}/repo/tests/verify-rc.ps1" \
		-Archive "${work}/rc/${archive}" \
		-Manifest "${work}/rc/manifest.json" \
		-Platform windows-x86_64 \
		-WorkDir "${work}/run" \
		-Json "${OUT}/verdict-windows-x86_64.json" \
		-Tag "$TAG" \
		-Commit "$COMMIT" || return 1
}

for p in linux-x86_64 linux-aarch64 darwin-arm64 darwin-x86_64 freebsd-x86_64 windows-x86_64; do
	run_leg "$p"
done

say_ 'Verdicts'
for f in "$OUT"/verdict-*.json; do
	[ -e "$f" ] || continue
	python3 - "$f" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
t = d.get('report', {}).get('totals', {})
print("  %-16s %-6s sha256=%s  %s/%s passed, %s failed" % (
    d.get('platform'), d.get('verdict'),
    (d.get('integrity') or {}).get('sha256', '?')[:16],
    t.get('passed'), t.get('total'), t.get('failed')))
PY
done
