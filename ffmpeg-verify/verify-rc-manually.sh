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
#   ./verify-rc-manually.sh --commit <sha> --stage-only
#
# Verdicts land in ./verdicts/verdict-<platform>.json next to this script.
#
# It can only verify a commit that CARRIES the verifier, because each leg runs
# tests/verify-rc.sh from the commit under test rather than from a copy that
# might have drifted. Aiming it at an older release fails with
# `repo/tests/verify-rc.sh: No such file or directory`, which is correct and
# not a fault to debug: the first verifiable RC is the first one built from a
# commit that has these scripts in it.
set -uo pipefail

REPO='NoMercy-Entertainment/nomercy-ffmpeg'
TAG=''
COMMIT=''
ONLY=''
# Stage without verifying: clone the commit under test on every machine and
# stop there. Worth its own mode because the clone is the slow half on the
# FreeBSD and Lima legs, and because a leg that cannot reach GitHub should
# surface before a release is waiting on it rather than after.
STAGE_ONLY=0
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
	--stage-only) STAGE_ONLY=1; shift ;;
	--out) OUT="$2"; shift 2 ;;
	*) echo "Unknown option: $1" >&2; exit 2 ;;
	esac
done

[ -n "$COMMIT" ] || { echo "Error: --commit is required." >&2; exit 2; }
if [ "$STAGE_ONLY" = 0 ] && [ -z "$TAG" ]; then
	echo "Error: --tag is required unless --stage-only." >&2
	exit 2
fi

SSH_OPTS='-o BatchMode=yes -o StrictHostKeyChecking=no -o ConnectTimeout=10'
mkdir -p "$OUT"

say_() { printf '\n\033[36m── %s\033[0m\n' "$1"; }
ok_() { printf '  \033[32m[ ok ]\033[0m %s\n' "$1"; }
bad_() { printf '  \033[31m[fail]\033[0m %s\n' "$1"; }

# The asset list, resolved once. Every machine fetches by API URL, which works
# the same whether the repository is public or private.
ASSETS=''
TOKEN="$(gh auth token)"
if [ "$STAGE_ONLY" = 0 ]; then
	ASSETS="$(gh api "repos/${REPO}/releases/tags/${TAG}" --jq '[.assets[] | {name, url}] | tojson')"
	[ -n "$ASSETS" ] || { echo "Error: release ${TAG} has no assets." >&2; exit 1; }

	RELEASE_TARGET="$(gh api "repos/${REPO}/releases/tags/${TAG}" --jq '.target_commitish')"
	if [ "$RELEASE_TARGET" != "$COMMIT" ]; then
		echo "Refusing: ${TAG} was built from ${RELEASE_TARGET}, not ${COMMIT}." >&2
		echo "Verifying it would produce verdicts for the wrong artifacts, which is the" >&2
		echo "exact failure this fleet exists to make impossible." >&2
		exit 1
	fi
fi

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
SCRIPT

	if [ "$STAGE_ONLY" = 1 ]; then
		cat <<'SCRIPT'
echo "staged $(git -C repo rev-parse --short HEAD) - $(uname -sm) - $(python3 -V 2>&1)"
exit 0
SCRIPT
		return 0
	fi

	cat <<SCRIPT

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

FAILED_LEGS=''

run_leg() {
	local platform="$1"
	[ -z "$ONLY" ] || [ "$ONLY" = "$platform" ] || return 0
	say_ "$platform"
	local did='verdict collected'
	[ "$STAGE_ONLY" = 0 ] || did='staged'
	if "leg_${platform//-/_}"; then
		ok_ "$platform ${did}"
	else
		bad_ "$platform FAILED"
		FAILED_LEGS="${FAILED_LEGS} ${platform}"
	fi
}

# ── linux-x86_64: the Proxmox container, as the runner user ────────────────
leg_linux_x86_64() {
	render_unix_script linux-x86_64 tar.gz |
		ssh $SSH_OPTS -i "$PROXMOX_KEY" "$PROXMOX" \
			"pct exec ${CT_ID} -- su - runner -c 'cat > /tmp/leg.sh'" || return 1
	ssh $SSH_OPTS -i "$PROXMOX_KEY" "$PROXMOX" \
		"pct exec ${CT_ID} -- su - runner -c 'bash /tmp/leg.sh'" || return 1
	[ "$STAGE_ONLY" = 0 ] || return 0
	ssh $SSH_OPTS -i "$PROXMOX_KEY" "$PROXMOX" \
		"pct exec ${CT_ID} -- su - runner -c 'cat ~/rc-verify/linux-x86_64/verdict-linux-x86_64.json'" \
		>"${OUT}/verdict-linux-x86_64.json"
}

# ── freebsd-x86_64: driven from that same container over SSH ───────────────
# The guest has no git and does not need one. The container clones, then ships
# tests/ and the artifacts across, exactly as verify-rc.yml does. Cloning on the
# guest instead is what a first staging run caught: `git: command not found`,
# which would have surfaced with a release waiting on it.
leg_freebsd_x86_64() {
	local driver
	driver="$(cat <<SCRIPT
set -euo pipefail
WORK="\${HOME}/rc-verify/freebsd-x86_64"
rm -rf "\$WORK" && mkdir -p "\$WORK/rc"
cd "\$WORK"

if [ ! -d repo/.git ]; then
	git clone -q --no-checkout "https://github.com/${REPO}.git" repo
fi
cd repo && git fetch -q origin "${COMMIT}" && git checkout -q "${COMMIT}" && cd ..

REMOTE=/tmp/ffmpeg-verify-manual
ssh ${SSH_OPTS} ${FREEBSD} "rm -rf \${REMOTE}; mkdir -p \${REMOTE}/rc"
tar -cf - -C repo tests | ssh ${SSH_OPTS} ${FREEBSD} "tar -xf - -C \${REMOTE}"
echo "shipped tests/ to the guest at \$(git -C repo rev-parse --short HEAD)"
SCRIPT
)"

	if [ "$STAGE_ONLY" = 0 ]; then
		driver="${driver}
$(cat <<SCRIPT
ARCHIVE=\$(printf '%s' '${ASSETS}' | python3 -c "import json,sys; print(next((a['name'] for a in json.load(sys.stdin) if 'freebsd-x86_64' in a['name'] and a['name'].endswith('tar.gz')),''))")
[ -n "\$ARCHIVE" ] || { echo "no freebsd archive in ${TAG}"; exit 1; }
for name in "\$ARCHIVE" manifest.json; do
	url=\$(printf '%s' '${ASSETS}' | N="\$name" python3 -c "import json,sys,os; print(next((a['url'] for a in json.load(sys.stdin) if a['name']==os.environ['N']),''))")
	curl -fsSL -H "Authorization: Bearer ${TOKEN}" -H "Accept: application/octet-stream" "\$url" -o "rc/\$name"
done
scp ${SSH_OPTS} "rc/\$ARCHIVE" rc/manifest.json ${FREEBSD}:\${REMOTE}/rc/

ssh ${SSH_OPTS} ${FREEBSD} "bash \${REMOTE}/tests/verify-rc.sh \\
	--archive \${REMOTE}/rc/\$ARCHIVE \\
	--manifest \${REMOTE}/rc/manifest.json \\
	--platform freebsd-x86_64 \\
	--workdir \${REMOTE}/w \\
	--json \${REMOTE}/verdict.json \\
	--tag ${TAG} \\
	--commit ${COMMIT}"
scp ${SSH_OPTS} ${FREEBSD}:\${REMOTE}/verdict.json "\$WORK/verdict-freebsd-x86_64.json"
SCRIPT
)"
	fi

	printf '%s\n' "$driver" |
		ssh $SSH_OPTS -i "$PROXMOX_KEY" "$PROXMOX" \
			"pct exec ${CT_ID} -- su - runner -c 'cat > /tmp/fb.sh'" || return 1
	ssh $SSH_OPTS -i "$PROXMOX_KEY" "$PROXMOX" \
		"pct exec ${CT_ID} -- su - runner -c 'bash /tmp/fb.sh'" || return 1
	[ "$STAGE_ONLY" = 0 ] || return 0
	ssh $SSH_OPTS -i "$PROXMOX_KEY" "$PROXMOX" \
		"pct exec ${CT_ID} -- su - runner -c 'cat ~/rc-verify/freebsd-x86_64/verdict-freebsd-x86_64.json'" \
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
	[ "$STAGE_ONLY" = 0 ] || return 0
	ssh $SSH_OPTS -i "$MAC_KEY" "$MAC" \
		"cat ~/rc-verify/${platform}/verdict-${platform}.json" >"${OUT}/verdict-${platform}.json"
}

# ── linux-aarch64: the Lima guest on that same Mac ─────────────────────────
leg_linux_aarch64() {
	render_unix_script linux-aarch64 tar.gz |
		ssh $SSH_OPTS -i "$MAC_KEY" "$MAC" "cat > /tmp/aarch64.sh" || return 1
	ssh $SSH_OPTS -i "$MAC_KEY" "$MAC" \
		"${LIMA_BIN} shell ${LIMA_INSTANCE} -- bash -s < /tmp/aarch64.sh" || return 1
	[ "$STAGE_ONLY" = 0 ] || return 0
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
	if [ "$STAGE_ONLY" = 1 ]; then
		echo "  staged $(git -C "${work}/repo" rev-parse --short HEAD) - windows - pwsh $(pwsh -NoProfile -Command '$PSVersionTable.PSVersion.ToString()' 2>/dev/null)"
		return 0
	fi

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

if [ -n "$(printf '%s' "$FAILED_LEGS" | tr -d ' ')" ]; then
	say_ 'Incomplete'
	printf '  These legs did not finish:%s
' "$FAILED_LEGS"
	printf '  A fleet that covers five platforms and reports six is the failure
'
	printf '  all of this exists to prevent, so this is an error and not a shorter list.

'
	exit 1
fi

if [ "$STAGE_ONLY" = 1 ]; then
	say_ 'Staged - every leg has the commit under test and can reach GitHub'
	exit 0
fi

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
