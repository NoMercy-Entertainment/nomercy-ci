#!/bin/bash
# Keeps the Mac's runners and the Lima guest up.
#
# Runs on an interval from a LaunchAgent. Two jobs:
#   1. Make sure the linux-aarch64 Lima guest is running. Nothing else starts
#      it, and without it that verification leg fails rather than queues.
#   2. Make sure every registered Actions runner service is loaded, and start
#      any that is not.
#
# Only ever starts things. It never stops or reconfigures a runner, so it is
# safe alongside runners owned by someone else.
set -uo pipefail

LIMA_BIN="${LIMA_BIN:-$HOME/lima/bin/limactl}"
LIMA_INSTANCE="${LIMA_INSTANCE:-linux-arm64}"
LOG="${LOG:-$HOME/Library/Logs/nomercy-runner-watchdog.log}"

mkdir -p "$(dirname "$LOG")"
say_() { printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$1" >>"$LOG"; }

# ── Lima guest ────────────────────────────────────────────────────────────
if [ -x "$LIMA_BIN" ]; then
	_state="$("$LIMA_BIN" list --format '{{.Status}}' "$LIMA_INSTANCE" 2>/dev/null | head -1)"
	if [ "$_state" != "Running" ]; then
		say_ "lima ${LIMA_INSTANCE} is '${_state:-absent}', starting it"

		# Broken is not Stopped. A guest killed mid-flight - a host reboot while
		# it was live is enough - leaves the vz driver process behind with no
		# host agent, and `limactl start` refuses that state forever. Every tick
		# then logs a fresh failure and nothing changes. Force-stop first so the
		# stale sockets and vz.pid are cleared, and starting works.
		#
		# Found after a reboot left this instance Broken for 19 hours while the
		# watchdog reported it was trying: the linux-aarch64 leg of the
		# verification fleet was simply gone, and only a manual look found it.
		if [ "$_state" = "Broken" ]; then
			say_ "lima ${LIMA_INSTANCE} is Broken, force-stopping before start"
			"$LIMA_BIN" stop --force "$LIMA_INSTANCE" >>"$LOG" 2>&1 || true
			sleep 3
		fi

		"$LIMA_BIN" start "$LIMA_INSTANCE" --tty=false >>"$LOG" 2>&1 &&
			say_ "lima ${LIMA_INSTANCE} started" ||
			say_ "lima ${LIMA_INSTANCE} FAILED to start"
	fi
fi

# ── Runner services ───────────────────────────────────────────────────────
# The service name is in each runner's .service file; the directory next to it
# owns svc.sh. Discovering them this way means a runner added later is covered
# without editing this script.
for _svc in "$HOME"/Library/LaunchAgents/actions.runner.*.plist; do
	[ -e "$_svc" ] || continue
	_label="$(basename "$_svc" .plist)"

	if launchctl print "gui/$(id -u)/${_label}" >/dev/null 2>&1; then
		continue
	fi

	say_ "${_label} is not loaded, bootstrapping it"
	if launchctl bootstrap "gui/$(id -u)" "$_svc" >>"$LOG" 2>&1; then
		say_ "${_label} bootstrapped"
	else
		say_ "${_label} FAILED to bootstrap"
	fi
done

# Keep the log from growing without bound; this runs every few minutes forever.
if [ -f "$LOG" ] && [ "$(wc -l <"$LOG")" -gt 2000 ]; then
	tail -500 "$LOG" >"${LOG}.tmp" && mv "${LOG}.tmp" "$LOG"
fi
