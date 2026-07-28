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
# Usage: install-macos-autostart.sh --auto-login [--user stoney]
#        install-macos-autostart.sh --auto-login --password-stdin <<<"$pw"
set -euo pipefail

USER_NAME="${USER:-$(id -un)}"
PASSWORD=""
WANT_AUTO_LOGIN=""
READ_STDIN=""
INTERVAL="${INTERVAL:-300}"
LIMA_INSTANCE="${LIMA_INSTANCE:-linux-arm64}"
LIMA_BIN="${LIMA_BIN:-$HOME/lima/bin/limactl}"

while [[ $# -gt 0 ]]; do
	case "$1" in
	# argv is readable via `ps` by any local user and lands in shell history,
	# so this stays available for automation but is not the documented path.
	--password) PASSWORD="$2"; WANT_AUTO_LOGIN=yes; shift 2 ;;
	--password-stdin) READ_STDIN=yes; WANT_AUTO_LOGIN=yes; shift ;;
	--auto-login) WANT_AUTO_LOGIN=yes; shift ;;
	--no-auto-login) WANT_AUTO_LOGIN=no; shift ;;
	--user) USER_NAME="$2"; shift 2 ;;
	--interval) INTERVAL="$2"; shift 2 ;;
	--lima-instance) LIMA_INSTANCE="$2"; shift 2 ;;
	*) echo "Unknown option: $1" >&2; exit 2 ;;
	esac
done

[[ "$(uname -s)" == "Darwin" ]] || { echo "macOS only." >&2; exit 2; }

# `fdesetup status` is localised, so matching its sentence refuses to run on a
# non-English system. `isactive` prints true/false in every locale.
if [[ "$(fdesetup isactive 2>/dev/null)" == "true" ]]; then
	echo "Refusing: FileVault is on, so auto-login cannot work and this would" >&2
	echo "leave you believing reboots are covered when they are not." >&2
	exit 1
fi

if [[ "$WANT_AUTO_LOGIN" == "yes" && -z "$PASSWORD" ]]; then
	if [[ -n "$READ_STDIN" ]]; then
		IFS= read -r PASSWORD
	elif [[ -t 0 ]]; then
		read -rsp "Login password for ${USER_NAME}: " PASSWORD
		echo
	else
		echo "No terminal to prompt on. Pass the password on stdin:" >&2
		echo "  install-macos-autostart.sh --auto-login --password-stdin <<<\"\$pw\"" >&2
		exit 2
	fi
	[[ -n "$PASSWORD" ]] || { echo "Empty password; not configuring auto-login." >&2; exit 2; }
fi

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AGENT_DIR="$HOME/Library/LaunchAgents"
BIN_DIR="$HOME/.local/bin"
WATCHDOG="$BIN_DIR/nomercy-runner-watchdog.sh"
LABEL="tv.nomercy.runner-watchdog"
HEALTH_LABEL="tv.nomercy.autologin-health"

mkdir -p "$AGENT_DIR" "$BIN_DIR"

# Anything written below holds or derives from the login password.
umask 077

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
		# mktemp gives an unpredictable name at mode 600, and the trap covers the
		# failure paths: until `install` runs, this file is the login password
		# behind a fixed XOR key, which is no protection at all.
		KCP_TMP="$(mktemp "${TMPDIR:-/tmp}/nomercy-kcp.XXXXXXXX")"
		trap 'rm -f "$KCP_TMP"' EXIT
		PASSWORD="$PASSWORD" python3 -c '
import os, sys
key = bytes([0x7D,0x89,0x52,0x23,0xD2,0xBC,0xDD,0xEA,0xA3,0xB9,0x1F])
raw = bytearray(os.environ["PASSWORD"].encode("utf-8"))
pad = 12 - (len(raw) % 12)
raw += b"\x00" * pad
sys.stdout.buffer.write(bytes(c ^ key[i % len(key)] for i, c in enumerate(raw)))
' >"$KCP_TMP"
		printf '%s\n' "$PASSWORD" | sudo -S -p '' install -m 600 -o root -g wheel "$KCP_TMP" /etc/kcpassword
		rm -f "$KCP_TMP"
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

	# The watchdog is a LaunchAgent, so it needs the very session auto-login
	# exists to create. If auto-login breaks — an OS update resetting the
	# preference, someone enabling FileVault — nothing below the login window
	# is running to notice. This daemon runs at boot outside any GUI session and
	# does nothing but say so. It cannot repair anything: it has no password,
	# and holding one would be worse than the problem.
	echo "── Auto-login health daemon ──"
	# /usr/local/bin does not exist on a clean Apple Silicon Mac — Homebrew lives
	# in /opt/homebrew and nothing else creates it.
	printf '%s\n' "$PASSWORD" | sudo -S -p '' install -d -m 755 -o root -g wheel /usr/local/bin
	printf '%s\n' "$PASSWORD" | sudo -S -p '' install -m 755 -o root -g wheel \
		"${HERE}/macos-autologin-healthcheck.sh" /usr/local/bin/nomercy-autologin-healthcheck.sh

	HEALTH_PLIST="$(mktemp "${TMPDIR:-/tmp}/nomercy-health.XXXXXXXX")"
	cat >"$HEALTH_PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>${HEALTH_LABEL}</string>
    <key>ProgramArguments</key>
    <array>
        <string>/bin/bash</string>
        <string>/usr/local/bin/nomercy-autologin-healthcheck.sh</string>
        <string>${USER_NAME}</string>
    </array>
    <key>RunAtLoad</key><true/>
    <key>StartInterval</key><integer>3600</integer>
    <key>ProcessType</key><string>Background</string>
</dict>
</plist>
PLIST
	printf '%s\n' "$PASSWORD" | sudo -S -p '' install -m 644 -o root -g wheel \
		"$HEALTH_PLIST" "/Library/LaunchDaemons/${HEALTH_LABEL}.plist"
	rm -f "$HEALTH_PLIST"

	printf '%s\n' "$PASSWORD" | sudo -S -p '' launchctl bootout "system/${HEALTH_LABEL}" 2>/dev/null || true
	printf '%s\n' "$PASSWORD" | sudo -S -p '' launchctl bootstrap system "/Library/LaunchDaemons/${HEALTH_LABEL}.plist"
	echo "Health daemon installed; it logs to /var/log/nomercy-autologin-health.log and the system log."
else
	echo "Auto-login not requested; leaving it as it is."
	echo "Without it, a reboot with nobody logged in leaves every runner down."
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
