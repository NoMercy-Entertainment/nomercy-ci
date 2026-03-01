#!/usr/bin/env bash
# HTTP/HTTPS endpoint health check

# check_service <ip> [port]
# Tries HTTP then HTTPS (with -k for self-signed certs).
# NoMercy starts on HTTP, acquires an SSL cert, then restarts on HTTPS,
# so both protocols are checked on the same port.
# Retries up to 20 times with 5s delay (100s total).
check_service() {
    local ip=$1
    local port=${2:-$WEB_PORT}
    local attempts=20
    local delay=5
    local i

    for ((i=1; i<=attempts; i++)); do
        # HTTP
        if curl -sf --max-time 5 "http://${ip}:${port}/" >/dev/null 2>&1; then
            return 0
        fi
        # HTTPS (allow self-signed)
        if curl -sfk --max-time 5 "https://${ip}:${port}/" >/dev/null 2>&1; then
            return 0
        fi
        sleep "$delay"
    done

    return 1
}
