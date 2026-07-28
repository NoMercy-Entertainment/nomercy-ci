#!/bin/bash
# Watches the one thing the runner watchdog cannot watch: auto-login itself.
#
# The watchdog is a LaunchAgent, so it only runs once a GUI session exists —
# which is exactly what auto-login is there to create. If auto-login breaks, the
# watchdog is not running either and nothing reports it. The machine simply
# comes back from a reboot with no runners and no explanation.
#
# This runs as a LaunchDaemon, at boot and hourly, outside any session. It only
# ever reports. It cannot repair auto-login, because repairing it needs the login
# password, and a root daemon holding that password would be a worse problem than
# the one it solves.
#
# Usage: nomercy-autologin-healthcheck.sh <expected-user>
set -uo pipefail

EXPECTED_USER="${1:-}"
LOG="/var/log/nomercy-autologin-health.log"

# The unified log records `logger` as the process and drops the tag, so the
# marker has to be in the message itself for anything to be searchable later.
say_() {
	printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$1" >>"$LOG"
	logger -t nomercy-autologin "nomercy-autologin: $1"
}

problems=0

configured_user="$(defaults read /Library/Preferences/com.apple.loginwindow autoLoginUser 2>/dev/null)"
if [ -z "$configured_user" ]; then
	say_ "BROKEN: autoLoginUser is unset. Runners will not come back from a reboot."
	problems=$((problems + 1))
elif [ -n "$EXPECTED_USER" ] && [ "$configured_user" != "$EXPECTED_USER" ]; then
	say_ "BROKEN: autoLoginUser is '${configured_user}', expected '${EXPECTED_USER}'."
	problems=$((problems + 1))
fi

# The credential half. sysadminctl can set the preference and fail this silently,
# which is the failure that started all of it.
if [ ! -f /etc/kcpassword ]; then
	say_ "BROKEN: /etc/kcpassword is missing. The login window will appear at boot."
	problems=$((problems + 1))
fi

# FileVault defeats auto-login outright, whatever the other two say.
if [ "$(fdesetup isactive 2>/dev/null)" = "true" ]; then
	say_ "BROKEN: FileVault is on, so auto-login cannot work regardless of the settings above."
	problems=$((problems + 1))
fi

rotate_() {
	if [ -f "$LOG" ] && [ "$(wc -l <"$LOG")" -gt 2000 ]; then
		tail -500 "$LOG" >"${LOG}.tmp" && mv "${LOG}.tmp" "$LOG"
	fi
}

if [ "$problems" -eq 0 ]; then
	# Writes on every run, including the one at boot. An hourly heartbeat is what
	# makes "the check is running and everything is fine" distinguishable from
	# "the check stopped running", and a silent boot run answers neither. Only
	# the file gets the ok line; the system log stays for the failures.
	printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "ok: auto-login intact for ${configured_user}" >>"$LOG"
	rotate_
	exit 0
fi

say_ "Fix with: install-macos-autostart.sh --auto-login"
rotate_
exit 1
