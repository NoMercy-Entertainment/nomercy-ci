#!/usr/bin/env bash
# Artifact collection — copies logs from test environments to RUN_DIR

_LOGS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${_LOGS_DIR}/../config.sh"

# collect_linux_logs <ip> <dest_dir> <distro_name>
collect_linux_logs() {
    local ip=$1
    local dest=$2
    local name=$3

    mkdir -p "$dest"

    # Install log (written by platforms/install_*.sh)
    # shellcheck disable=SC2086
    scp $SSH_OPTS "${SSH_USER}@${ip}:/tmp/install.log" \
        "${dest}/${name}-install.log" 2>/dev/null || true

    # Service log (written by systemd unit)
    # shellcheck disable=SC2086
    ssh $SSH_OPTS "${SSH_USER}@${ip}" \
        "journalctl -u nomercymediaserver --no-pager -n 500 2>/dev/null || true" \
        > "${dest}/${name}-journal.log" 2>/dev/null || true

    # System info snapshot
    # shellcheck disable=SC2086
    ssh $SSH_OPTS "${SSH_USER}@${ip}" \
        "uname -a; echo '---'; free -m; echo '---'; df -h" \
        > "${dest}/${name}-sysinfo.txt" 2>/dev/null || true
}

# collect_windows_logs <ip> <dest_dir>
collect_windows_logs() {
    local ip=$1
    local dest=$2

    mkdir -p "$dest"

    # Install log (written by platforms/install_windows.ps1)
    # shellcheck disable=SC2086
    scp $SSH_OPTS "${SSH_USER}@${ip}:C:/ci/install.log" \
        "${dest}/windows-install.log" 2>/dev/null || true

    # Server log
    # shellcheck disable=SC2086
    scp $SSH_OPTS "${SSH_USER}@${ip}:C:/ci/server.log" \
        "${dest}/windows-server.log" 2>/dev/null || true

    # Windows event log for the service (last 100 entries)
    # shellcheck disable=SC2086
    ssh $SSH_OPTS "${SSH_USER}@${ip}" \
        'powershell -Command "Get-EventLog -LogName Application -Source *NoMercy* -Newest 100 -ErrorAction SilentlyContinue | Format-List | Out-String"' \
        > "${dest}/windows-events.log" 2>/dev/null || true

    # System info
    # shellcheck disable=SC2086
    ssh $SSH_OPTS "${SSH_USER}@${ip}" \
        'powershell -Command "Get-ComputerInfo | Select-Object OsName,OsVersion,TotalPhysicalMemory | Format-List | Out-String"' \
        > "${dest}/windows-sysinfo.txt" 2>/dev/null || true
}
