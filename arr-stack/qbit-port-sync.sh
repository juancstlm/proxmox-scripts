#!/bin/sh
# qbit-port-sync.sh
# -----------------
# Reads ProtonVPN's NAT-PMP forwarded port from a file gluetun writes
# into a shared volume, and pushes it to qBittorrent's listen_port
# whenever it changes. No API calls to gluetun's control server, so
# nothing to maintain in /gluetun/auth/config.toml.
#
# Requires gluetun to be configured with:
#   VPN_PORT_FORWARDING_STATUS_FILE=/gluetun/forwarded_port
# That writes the port to the host-mounted volume at
# ${CONFIG_PATH}/gluetun/forwarded_port. This sidecar mounts the same
# host path read-only at /gluetun.
#
# qBittorrent's WebUI must allow this container's IP (the compose
# default-bridge subnet, typically 172.16.0.0/12) via:
#   Tools → Options → Web UI →
#     "Bypass authentication for clients in whitelisted IP subnets"
#
# Env:
#   SYNC_INTERVAL   seconds between polls (default 120)
#   PORT_FILE       default /gluetun/forwarded_port
#   QBIT_URL        default http://gluetun:8080

set -eu

if ! command -v curl >/dev/null 2>&1; then
    apk add --no-cache curl >/dev/null 2>&1
fi

INTERVAL="${SYNC_INTERVAL:-120}"
PORT_FILE="${PORT_FILE:-/gluetun/forwarded_port}"
QBIT_URL="${QBIT_URL:-http://gluetun:8080}"

log() { printf '%s [port-sync] %s\n' "$(date -u +%FT%TZ)" "$*"; }

log "starting — port_file=${PORT_FILE} qbittorrent=${QBIT_URL} interval=${INTERVAL}s"

# Wait until gluetun has actually written the file. Saves a flurry of
# noisy error lines while the stack is still coming up cold.
while [ ! -s "${PORT_FILE}" ]; do
    log "waiting for gluetun to write ${PORT_FILE}..."
    sleep 5
done

LAST_PORT=0
while :; do
    PORT="$(tr -d '[:space:]' < "${PORT_FILE}" 2>/dev/null || true)"

    case "${PORT:-}" in
        ''|0)
            log "port file is empty/zero — waiting for gluetun to refresh"
            ;;
        "$LAST_PORT")
            : # unchanged, stay quiet
            ;;
        *)
            if printf '%s' "${PORT}" | grep -Eq '^[0-9]+$'; then
                log "forwarded port changed: ${LAST_PORT} -> ${PORT} — updating qBittorrent"
                if curl -fsS --data-urlencode "json={\"listen_port\": ${PORT}}" \
                    "${QBIT_URL}/api/v2/app/setPreferences" >/dev/null 2>&1; then
                    LAST_PORT="${PORT}"
                    log "qBittorrent listen_port = ${PORT}"
                else
                    log "POST to qBittorrent failed — is the WebUI whitelist enabled for the compose subnet?"
                fi
            else
                log "invalid port value in ${PORT_FILE}: ${PORT}"
            fi
            ;;
    esac

    sleep "${INTERVAL}"
done
