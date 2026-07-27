#!/usr/bin/env bash
# Installs a persistent GitHub Actions runner on a Unix host (Linux or macOS)
# and registers it against the NoMercy org with a fixed label set.
#
# Persistent, not ephemeral, on purpose. The RC verification fleet is judged on
# whether a green tick means the hardware really ran the suite, so each target
# is pinned to one known machine rather than whichever pool slot answered
# first. Each verify job wipes its own workdir, so state does not accumulate.
#
# Run this ON the target host:
#   install-runner.sh --name ffmpeg-verify-linux \
#                     --labels ffmpeg-verify,linux-x86_64 \
#                     --token <registration token>
set -euo pipefail

ORG="NoMercy-Entertainment"
RUNNER_VERSION="2.336.0"
RUNNER_USER="${SUDO_USER:-$(id -un)}"
RUNNER_HOME=""
NAME=""
LABELS=""
TOKEN=""

while [[ $# -gt 0 ]]; do
	case "$1" in
	--name) NAME="$2"; shift 2 ;;
	--labels) LABELS="$2"; shift 2 ;;
	--token) TOKEN="$2"; shift 2 ;;
	--org) ORG="$2"; shift 2 ;;
	--user) RUNNER_USER="$2"; shift 2 ;;
	--version) RUNNER_VERSION="$2"; shift 2 ;;
	*) echo "Error: unknown argument '$1'." >&2; exit 2 ;;
	esac
done

[[ -n "$NAME" ]] || { echo "Error: --name is required." >&2; exit 2; }
[[ -n "$LABELS" ]] || { echo "Error: --labels is required." >&2; exit 2; }
[[ -n "$TOKEN" ]] || { echo "Error: --token is required." >&2; exit 2; }

case "$(uname -s)" in
Linux) PLATFORM="linux" ;;
Darwin) PLATFORM="osx" ;;
*) echo "Error: $(uname -s) has no official Actions runner build." >&2; exit 2 ;;
esac

case "$(uname -m)" in
x86_64 | amd64) ARCH="x64" ;;
aarch64 | arm64) ARCH="arm64" ;;
*) echo "Error: unsupported CPU $(uname -m)." >&2; exit 2 ;;
esac

if [[ "$(id -u)" -eq 0 && "$RUNNER_USER" == "root" ]]; then
	# The runner refuses to execute jobs as root. Give it its own account.
	RUNNER_USER="runner"
	if ! id -u "$RUNNER_USER" >/dev/null 2>&1; then
		useradd -m -s /bin/bash "$RUNNER_USER"
		echo "Created service account '${RUNNER_USER}'."
	fi
fi

RUNNER_HOME="$(eval echo "~${RUNNER_USER}")/actions-runner-${NAME}"
TARBALL="actions-runner-${PLATFORM}-${ARCH}-${RUNNER_VERSION}.tar.gz"
URL="https://github.com/actions/runner/releases/download/v${RUNNER_VERSION}/${TARBALL}"

echo "─── ${NAME} :: ${PLATFORM}-${ARCH} :: ${LABELS} ───"

if [[ -f "${RUNNER_HOME}/.runner" ]]; then
	echo "Runner already configured at ${RUNNER_HOME}; removing before re-registering."
	if [[ -x "${RUNNER_HOME}/svc.sh" ]]; then
		(cd "$RUNNER_HOME" && ./svc.sh stop 2>/dev/null || true)
		(cd "$RUNNER_HOME" && ./svc.sh uninstall 2>/dev/null || true)
	fi
	su - "$RUNNER_USER" -c "cd '${RUNNER_HOME}' && ./config.sh remove --token '${TOKEN}'" 2>/dev/null || true
fi

mkdir -p "$RUNNER_HOME"
chown -R "$RUNNER_USER" "$RUNNER_HOME"

if [[ ! -f "${RUNNER_HOME}/config.sh" ]]; then
	echo "Downloading runner ${RUNNER_VERSION}…"
	curl -fsSL -o "/tmp/${TARBALL}" "$URL"
	tar -xzf "/tmp/${TARBALL}" -C "$RUNNER_HOME"
	rm -f "/tmp/${TARBALL}"
	chown -R "$RUNNER_USER" "$RUNNER_HOME"
fi

# --replace so re-running this script re-homes an existing registration instead
# of leaving a dead duplicate in the org runner list.
su - "$RUNNER_USER" -c "cd '${RUNNER_HOME}' && ./config.sh \
	--unattended --replace \
	--url 'https://github.com/${ORG}' \
	--token '${TOKEN}' \
	--name '${NAME}' \
	--labels '${LABELS}' \
	--work '_work'"

if [[ "$PLATFORM" == "linux" ]]; then
	(cd "$RUNNER_HOME" && ./svc.sh install "$RUNNER_USER" && ./svc.sh start)
	(cd "$RUNNER_HOME" && ./svc.sh status | head -5)
else
	su - "$RUNNER_USER" -c "cd '${RUNNER_HOME}' && ./svc.sh install && ./svc.sh start" || {
		echo "::warning::svc.sh needs a login session on macOS; start it once by hand."
	}
fi

echo "✅ ${NAME} registered with labels: ${LABELS}"
