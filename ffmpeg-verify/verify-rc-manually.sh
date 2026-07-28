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
# Verdicts land in ./verdicts/verdict-<platform>.json next to this script, and
# are read back only for the legs THIS run drove, after checking each one names
# the tag and commit under test. A verdict file on disk is not evidence on its
# own: it has to say which build it came from, or it is last week's answer to
# this week's question.
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

# The fleet, named once. --platform is checked against this and the driving
# loop iterates it, so the two can never disagree about what a platform is.
PLATFORMS='linux-x86_64 linux-aarch64 darwin-arm64 darwin-x86_64 freebsd-x86_64 windows-x86_64'

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

# A mistyped platform used to be indistinguishable from a filter that matched
# nothing: every leg skipped, no failures recorded, exit 0. That is the shape
# of a green run that drove no hardware at all, so it is an error now.
if [ -n "$ONLY" ]; then
	case " ${PLATFORMS} " in
	*" ${ONLY} "*) ;;
	*)
		echo "Error: unknown platform '${ONLY}'." >&2
		echo "Known platforms: ${PLATFORMS}" >&2
		exit 2
		;;
	esac
fi

case "$COMMIT" in
*[!0-9a-fA-F]*)
	echo "Error: --commit must be a hex sha, got '${COMMIT}'." >&2
	exit 2
	;;
esac
if [ ${#COMMIT} -lt 7 ]; then
	echo "Error: --commit must be at least 7 characters, got '${COMMIT}'." >&2
	exit 2
fi

# Resolved to the full sha once, up front, because a human drives this and will
# paste an abbreviation. Two things downstream need the long form: fetching a
# commit by sha from GitHub only works with all 40 characters, and every verdict
# records whatever is passed here — an abbreviation would make the evidence
# weaker than the workflow's, which always has headRefOid to hand.
COMMIT_FULL="$(gh api "repos/${REPO}/commits/${COMMIT}" --jq '.sha' 2>/dev/null)" || COMMIT_FULL=''
# gh prints the API's error body on stdout when a lookup is refused, so this has
# to be checked for being a sha rather than merely for being non-empty — an
# unchecked capture carries a JSON blob forward as though it were one.
case "$COMMIT_FULL" in
''|*[!0-9a-fA-F]*) COMMIT_FULL='' ;;
esac
if [ ${#COMMIT_FULL} -ne 40 ]; then
	echo "Error: ${COMMIT} is not a commit in ${REPO}." >&2
	exit 1
fi
[ "$COMMIT_FULL" = "$COMMIT" ] || echo "Resolved ${COMMIT} to ${COMMIT_FULL}."
COMMIT="$COMMIT_FULL"

SSH_OPTS='-o BatchMode=yes -o StrictHostKeyChecking=no -o ConnectTimeout=10'
mkdir -p "$OUT"

say_() { printf '\n\033[36m── %s\033[0m\n' "$1"; }
ok_() { printf '  \033[32m[ ok ]\033[0m %s\n' "$1"; }
bad_() { printf '  \033[31m[fail]\033[0m %s\n' "$1"; }

# The asset list, resolved once. Every machine fetches by API URL, which works
# the same whether the repository is public or private.
ASSETS=''
TOKEN=''
if [ "$STAGE_ONLY" = 0 ]; then
	# Only fetched when there is something to download. Staging needs no token.
	TOKEN="$(gh auth token)" || { echo "Error: could not read a token from gh." >&2; exit 1; }
	[ -n "$TOKEN" ] || { echo "Error: gh returned an empty token; run 'gh auth login'." >&2; exit 1; }

	ASSETS="$(gh api "repos/${REPO}/releases/tags/${TAG}" --jq '[.assets[] | {name, url}] | tojson')"
	[ -n "$ASSETS" ] || { echo "Error: release ${TAG} has no assets." >&2; exit 1; }

	RELEASE_TARGET="$(gh api "repos/${REPO}/releases/tags/${TAG}" --jq '.target_commitish')"

	# Both sides are full shas by the time this runs, so the comparison is exact.
	if [ "$(printf '%s' "$RELEASE_TARGET" | tr 'A-Z' 'a-z')" != "$(printf '%s' "$COMMIT" | tr 'A-Z' 'a-z')" ]; then
		echo "Refusing: ${TAG} was built from ${RELEASE_TARGET}, not ${COMMIT}." >&2
		echo "Verifying it would produce verdicts for the wrong artifacts, which is the" >&2
		echo "exact failure this fleet exists to make impossible." >&2
		case "$RELEASE_TARGET" in
		*[!0-9a-fA-F]*)
			echo >&2
			echo "Note: ${TAG} records a branch name rather than a commit, which is how a" >&2
			echo "release cut from a branch looks. Only the RC prereleases pin a sha, and" >&2
			echo "only those can be checked against one." >&2
			;;
		esac
		exit 1
	fi
fi

# The body run on every unix leg. Staged as a file rather than an ssh one-liner
# so quoting survives the two or three hops some of these take.
#
# The staged file deliberately carries no credential. The token is read from
# stdin at execution time and written to a 0600 curl config that is removed on
# exit, so it lives neither in a /tmp file that outlasts the run nor in the
# process table, where `curl -H "Authorization: ..."` would otherwise put it.
render_unix_script() {
	local platform="$1" ext="$2"
	cat <<SCRIPT
set -euo pipefail
read -r GH_TOKEN || GH_TOKEN=''

WORK="\${HOME}/rc-verify/${platform}"
mkdir -p "\$WORK"
cd "\$WORK"

# Clear what the last run produced, but keep repo/ so the clone is paid once per
# machine instead of once per run — it is the slow half on the FreeBSD and Lima
# legs. A stale checkout is not a risk: the fetch and checkout below pin it to
# the commit under test.
rm -rf rc run verdict-*.json
mkdir -p rc

CURLRC="\$WORK/.curlrc"
trap 'rm -f "\$CURLRC"' EXIT
(umask 077; printf 'header = "Authorization: Bearer %s"\n' "\$GH_TOKEN" >"\$CURLRC")

# The suite and its helpers come from the commit under test, not from whatever
# happens to be checked out on the machine.
if [ ! -d repo/.git ]; then
	rm -rf repo
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
	curl -fsSL --config "\$CURLRC" -H "Accept: application/octet-stream" "\$url" -o "rc/\$name"
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
RAN_LEGS=''

run_leg() {
	local platform="$1"
	[ -z "$ONLY" ] || [ "$ONLY" = "$platform" ] || return 0
	say_ "$platform"
	local did='verdict collected'
	[ "$STAGE_ONLY" = 0 ] || did='staged'
	# Drop any verdict an earlier run left here before this one has a chance to
	# fail. A leg that dies past this point must leave nothing behind, or the
	# summary would read last week's bytes as this run's result.
	rm -f "${OUT}/verdict-${platform}.json"
	if "leg_${platform//-/_}"; then
		# The collecting redirect creates the file whether or not the machine had
		# anything to send, so a leg can exit 0 having produced nothing. Say so
		# here rather than letting the line read `ok` and the run fail later.
		if [ "$STAGE_ONLY" = 0 ] && [ ! -s "${OUT}/verdict-${platform}.json" ]; then
			bad_ "$platform returned no verdict"
			FAILED_LEGS="${FAILED_LEGS} ${platform}"
			return 0
		fi
		ok_ "$platform ${did}"
		RAN_LEGS="${RAN_LEGS} ${platform}"
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
	printf '%s\n' "$TOKEN" |
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
read -r GH_TOKEN || GH_TOKEN=''

WORK="\${HOME}/rc-verify/freebsd-x86_64"
mkdir -p "\$WORK"
cd "\$WORK"

rm -rf rc run verdict-*.json
mkdir -p rc

CURLRC="\$WORK/.curlrc"
trap 'rm -f "\$CURLRC"' EXIT
(umask 077; printf 'header = "Authorization: Bearer %s"\n' "\$GH_TOKEN" >"\$CURLRC")

if [ ! -d repo/.git ]; then
	rm -rf repo
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
	curl -fsSL --config "\$CURLRC" -H "Accept: application/octet-stream" "\$url" -o "rc/\$name"
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
	printf '%s\n' "$TOKEN" |
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
	printf '%s\n' "$TOKEN" |
		ssh $SSH_OPTS -i "$MAC_KEY" "$MAC" "bash /tmp/${platform}.sh" || return 1
	[ "$STAGE_ONLY" = 0 ] || return 0
	ssh $SSH_OPTS -i "$MAC_KEY" "$MAC" \
		"cat ~/rc-verify/${platform}/verdict-${platform}.json" >"${OUT}/verdict-${platform}.json"
}

# ── linux-aarch64: the Lima guest on that same Mac ─────────────────────────
# Staged into the guest rather than fed to `bash -s` from the Mac's copy: the
# script now reads its token from stdin, and `bash -s < file` would have spent
# stdin on the script itself.
leg_linux_aarch64() {
	render_unix_script linux-aarch64 tar.gz |
		ssh $SSH_OPTS -i "$MAC_KEY" "$MAC" "cat > /tmp/aarch64.sh" || return 1
	ssh $SSH_OPTS -i "$MAC_KEY" "$MAC" \
		"${LIMA_BIN} shell ${LIMA_INSTANCE} -- sh -c 'cat > /tmp/aarch64.sh' < /tmp/aarch64.sh" || return 1
	printf '%s\n' "$TOKEN" |
		ssh $SSH_OPTS -i "$MAC_KEY" "$MAC" \
			"${LIMA_BIN} shell ${LIMA_INSTANCE} -- bash /tmp/aarch64.sh" || return 1
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
#
# Paths need converting in both directions here and nowhere else: $LOCALAPPDATA
# arrives as C:\Users\...\AppData\Local, which is not what rm -rf and mkdir want,
# and pwsh will not take the /c/Users/... form that they do.
win_work_dir() {
	local base="$HOME"
	if [ -n "${LOCALAPPDATA:-}" ] && command -v cygpath >/dev/null 2>&1; then
		base="$(cygpath -u "$LOCALAPPDATA")"
	fi
	printf '%s/rc-verify/windows-x86_64\n' "$base"
}

win_path() {
	if command -v cygpath >/dev/null 2>&1; then
		cygpath -w "$1"
	else
		printf '%s\n' "$1"
	fi
}

leg_windows_x86_64() {
	local work
	work="$(win_work_dir)"
	mkdir -p "$work" || return 1
	rm -rf "${work}/rc" "${work}/run" || return 1
	mkdir -p "${work}/rc" || return 1

	if [ ! -d "${work}/repo/.git" ]; then
		rm -rf "${work}/repo"
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

	# Same reasoning as the remote legs: the token goes in a 0600 config that is
	# removed on the way out, not onto a command line.
	local curlrc="${work}/.curlrc"
	trap 'rm -f "${work}/.curlrc"' RETURN
	(umask 077; printf 'header = "Authorization: Bearer %s"\n' "$TOKEN" >"$curlrc") || return 1

	local name url
	for name in "$archive" manifest.json; do
		url="$(printf '%s' "$ASSETS" | N="$name" python3 -c "import json,sys,os; print(next((a['url'] for a in json.load(sys.stdin) if a['name']==os.environ['N']),''))")"
		[ -n "$url" ] || { echo "  asset ${name} missing from ${TAG}"; return 1; }
		curl -fsSL --config "$curlrc" -H 'Accept: application/octet-stream' "$url" -o "${work}/rc/${name}" || return 1
	done

	pwsh -NoProfile -File "$(win_path "${work}/repo/tests/verify-rc.ps1")" \
		-Archive "$(win_path "${work}/rc/${archive}")" \
		-Manifest "$(win_path "${work}/rc/manifest.json")" \
		-Platform windows-x86_64 \
		-WorkDir "$(win_path "${work}/run")" \
		-Json "$(win_path "${OUT}/verdict-windows-x86_64.json")" \
		-Tag "$TAG" \
		-Commit "$COMMIT" || return 1
}

for p in $PLATFORMS; do
	run_leg "$p"
done

if [ -n "$(printf '%s' "$FAILED_LEGS" | tr -d ' ')" ]; then
	say_ 'Incomplete'
	printf '  These legs did not finish:%s\n' "$FAILED_LEGS"
	printf '  A fleet that covers five platforms and reports six is the failure\n'
	printf '  all of this exists to prevent, so this is an error and not a shorter list.\n\n'
	exit 1
fi

if [ "$STAGE_ONLY" = 1 ]; then
	say_ 'Staged - every leg has the commit under test and can reach GitHub'
	exit 0
fi

say_ 'Verdicts'
SUMMARY_BAD=0
for p in $RAN_LEGS; do
	f="${OUT}/verdict-${p}.json"
	if [ ! -s "$f" ]; then
		bad_ "${p}: no verdict at ${f}"
		SUMMARY_BAD=1
		continue
	fi
	# Read back only what this run drove, and only after the file says which
	# build it came from. Globbing the directory instead would report a verdict
	# left by an earlier run against an earlier tag as though it were this one.
	TAG="$TAG" COMMIT="$COMMIT" python3 - "$f" "$p" <<'PY' || SUMMARY_BAD=1
import json, os, sys

path, platform = sys.argv[1], sys.argv[2]
try:
    with open(path) as fh:
        d = json.load(fh)
except (ValueError, OSError) as exc:
    print("  %-16s UNREADABLE  %s" % (platform, exc))
    raise SystemExit(1)

want_tag, want_commit = os.environ["TAG"], os.environ["COMMIT"]
got_tag, got_commit = d.get("tag") or "", d.get("commit") or ""
n = min(len(want_commit), len(got_commit))
if got_tag != want_tag or not n or got_commit[:n].lower() != want_commit[:n].lower():
    print("  %-16s MISMATCH    verdict is for %s @ %s, not %s @ %s" % (
        platform, got_tag or "?", (got_commit or "?")[:12], want_tag, want_commit[:12]))
    raise SystemExit(1)

if d.get("platform") != platform:
    print("  %-16s MISMATCH    verdict names platform %s" % (platform, d.get("platform")))
    raise SystemExit(1)

t = (d.get("report") or {}).get("totals") or {}
print("  %-16s %-6s sha256=%s  %s/%s passed, %s failed" % (
    platform, d.get("verdict"),
    (d.get("integrity") or {}).get("sha256", "?")[:16],
    t.get("passed"), t.get("total"), t.get("failed")))
PY
done

if [ "$SUMMARY_BAD" != 0 ]; then
	say_ 'Unusable verdicts'
	printf '  A verdict that cannot name %s @ %s proves nothing about it, so this\n' "$TAG" "$COMMIT"
	printf '  run has no result to report rather than a partial one.\n\n'
	exit 1
fi
