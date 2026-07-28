#!/usr/bin/env bash
# Makes the Mac's runners survive a reboot with nobody at the keyboard.
#
# The problem: actions-runner's svc.sh only ever produces a user LaunchAgent
# (~/Library/LaunchAgents, launchd domain gui/<uid>). LaunchAgents load at USER
# LOGIN, not at boot, so after an unattended reboot every runner on the machine
# stays down until someone logs in.
#
# Hand-writing a LaunchDaemon is the obvious fix and the wrong one: the runner
# requires runsvc.sh as its entry point and svc.sh is the supported path, and a
# daemon outside the GUI session loses the user keychain, code-signing
# identities and simulators that the Xcode runner needs.
#
# So: make the login happen. Auto-login brings up the GUI session at boot, the
# LaunchAgents load normally, and everything keeps working the way it does when
# a human logs in. A watchdog then covers the rest — a crashed runner, or the
# Lima guest that nothing else would start.
#
# Auto-login needs FileVault to be off. It already is on this host, so the disk
# is unencrypted either way and auto-login does not change the physical-access
# picture. Do not run this on a machine where that is not already true.
#
# Usage: install-macos-autostart.sh --password <login password> [--user stoney]
set -euo pipefail

USER_NAME="${USER:-$(id -un)}"
PASSWORD=""
INTERVAL="${INTERVAL:-300}"
LIMA_INSTANCE="${LIMA_INSTANCE:-linux-arm64}"
LIMA_BIN="${LIMA_BIN:-$HOME/lima/bin/limactl}"

while [[ $# -gt 0 ]]; do
	case "$1" in
	--password) PASSWORD="$2"; shift 2 ;;
	--user) USER_NAME="$2"; shift 2 ;;
	--interval) INTERVAL="$2"; shift 2 ;;
	--lima-instance) LIMA_INSTANCE="$2"; shift 2 ;;
	*) echo "Unknown option: $1" >&2; exit 2 ;;
	esac
done

[[ "$(uname -s)" == "Darwin" ]] || { echo "macOS only." >&2; exit 2; }

if [[ "$(fdesetup status 2>/dev/null)" != "FileVault is Off."* ]]; then
	echo "Refusing: FileVault is on, so auto-login cannot work and this would" >&2
	echo "leave you believing reboots are covered when they are not." >&2
	exit 1
fi

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AGENT_DIR="$HOME/Library/LaunchAgents"
BIN_DIR="$HOME/.local/bin"
WATCHDOG="$BIN_DIR/nomercy-runner-watchdog.sh"
LABEL="tv.nomercy.runner-watchdog"

mkdir -p "$AGENT_DIR" "$BIN_DIR"

echo "── Auto-login ──"
if [[ -n "$PASSWORD" ]]; then
	# sysadminctl is the supported route, but on macOS 26 it sets the user
	# preference and then fails to write the credential with
	# "SACSetAutoLoginPassword error:22", which leaves auto-login configured but
	# non-functional. Try it, then verify and fall back to writing
	# /etc/kcpassword directly. sudo -S because this is driven over SSH, where
	# sudo has no tty to prompt on.
	printf '%s\n' "$PASSWORD" |
		sudo -S -p '' sysadminctl -autologin set -userName "$USER_NAME" -password "$PASSWORD" 2>/dev/null || true

	if ! printf '%s\n' "$PASSWORD" | sudo -S -p '' test -f /etc/kcpassword; then
		echo "sysadminctl did not write /etc/kcpassword; writing it directly."
		# The classic loginwindow obfuscation: XOR against a fixed key, zero
		# padded to a multiple of 12 (a whole extra block when already aligned).
		PASSWORD="$PASSWORD" python3 -c '
import os, sys
key = bytes([0x7D,0x89,0x52,0x23,0xD2,0xBC,0xDD,0xEA,0xA3,0xB9,0x1F])
raw = bytearray(os.environ["PASSWORD"].encode("utf-8"))
pad = 12 - (len(raw) % 12)
raw += b"\x00" * pad
sys.stdout.buffer.write(bytes(c ^ key[i % len(key)] for i, c in enumerate(raw)))
' >/tmp/.kcp.$$
		printf '%s\n' "$PASSWORD" | sudo -S -p '' install -m 600 -o root -g wheel /tmp/.kcp.$$ /etc/kcpassword
		rm -f /tmp/.kcp.$$
	fi

	printf '%s\n' "$PASSWORD" | sudo -S -p '' defaults write \
		/Library/Preferences/com.apple.loginwindow autoLoginUser "$USER_NAME"

	# Verify BOTH halves. The preference alone is what made this look configured
	# while the login window still appeared at boot.
	_current="$(defaults read /Library/Preferences/com.apple.loginwindow autoLoginUser 2>/dev/null || true)"
	[[ "$_current" == "$USER_NAME" ]] ||
		{ echo "Auto-login user did not take (got '${_current:-none}')." >&2; exit 1; }
	printf '%s\n' "$PASSWORD" | sudo -S -p '' test -f /etc/kcpassword ||
		{ echo "/etc/kcpassword is still missing; auto-login would not work." >&2; exit 1; }
	echo "Auto-login enabled for ${USER_NAME} (user preference and credential both present)."
else
	echo "No --password given; leaving auto-login as it is."
fi

echo "── Watchdog ──"
install -m 755 "${HERE}/macos-autostart-watchdog.sh" "$WATCHDOG"

cat >"${AGENT_DIR}/${LABEL}.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>${LABEL}</string>
    <key>ProgramArguments</key>
    <array>
        <string>/bin/bash</string>
        <string>${WATCHDOG}</string>
    </array>
    <key>EnvironmentVariables</key>
    <dict>
        <key>LIMA_BIN</key><string>${LIMA_BIN}</string>
        <key>LIMA_INSTANCE</key><string>${LIMA_INSTANCE}</string>
    </dict>
    <key>RunAtLoad</key><true/>
    <key>StartInterval</key><integer>${INTERVAL}</integer>
    <key>ProcessType</key><string>Background</string>
    <key>StandardErrorPath</key><string>${HOME}/Library/Logs/nomercy-runner-watchdog.err</string>
</dict>
</plist>
PLIST

launchctl bootout "gui/$(id -u)/${LABEL}" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "${AGENT_DIR}/${LABEL}.plist"
launchctl kickstart "gui/$(id -u)/${LABEL}"

echo "Watchdog installed, running every ${INTERVAL}s."
echo
echo "Covered runners:"
for _p in "$HOME"/Library/LaunchAgents/actions.runner.*.plist; do
	[[ -e "$_p" ]] && echo "  $(basename "$_p" .plist)"
done
echo
echo "Reboot to confirm. Nothing here is proven until the machine has come back"
echo "up on its own with no one logged in."
