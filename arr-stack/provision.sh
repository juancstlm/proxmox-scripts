#!/usr/bin/env bash
# provision.sh
# ------------
# Runs INSIDE the freshly-created arr-stack VM. Installs Docker, mounts the
# UNAS jellyfish share over CIFS, writes /opt/arr-stack/{compose.yaml,.env},
# and brings up the compose stack.
#
# Normally invoked by ../setup-arr-vm.sh over SSH. All inputs come from env
# vars — there is no interactive prompting here.
#
# Required env:
#   WG_PRIVATE_KEY       ProtonVPN WireGuard private key
#   WG_ADDRESSES         WG client address (e.g. 10.2.0.2/32)
#   SMB_USERNAME         UNAS SMB user with read+write on the jellyfish share
#   SMB_PASSWORD         password for that user
#
# Optional env (with defaults):
#   STACK_HOME           default: /opt/arr-stack
#   STACK_USER           default: whoever owns ${STACK_UID} (typically the
#                        cloud-init user `juanc`); else `arr`
#   STACK_UID            default: 1000
#   STACK_GID            default: 1000
#   TZ                   default: America/Los_Angeles
#   LAN                  default: 10.8.1.0/24,192.168.0.0/24
#   VPN_COUNTRIES        default: United States
#   UNAS_HOST            default: 192.168.0.111
#   UNAS_SHARE           default: jellyfish
#   MEDIA_MOUNT          default: /mnt/jellyfish
#
# Flags:
#   --force-env          overwrite .env even if it already exists
#   --skip-up            install everything but don't run `docker compose up`

set -euo pipefail

STACK_HOME="${STACK_HOME:-/opt/arr-stack}"
STACK_UID="${STACK_UID:-1000}"
STACK_GID="${STACK_GID:-1000}"

# If a user already owns the target UID (typical when cloud-init created
# the default account at UID 1000), reuse them as the stack user instead
# of trying to add a colliding `arr`. The compose file hard-codes
# PUID=1000/PGID=1000, so whoever owns 1000 is the right account.
if [ -z "${STACK_USER:-}" ]; then
    existing_user_at_uid="$(getent passwd "${STACK_UID}" 2>/dev/null | cut -d: -f1 || true)"
    if [ -n "$existing_user_at_uid" ]; then
        STACK_USER="$existing_user_at_uid"
    else
        STACK_USER="arr"
    fi
fi
TZ="${TZ:-America/Los_Angeles}"
LAN="${LAN:-10.8.1.0/24,192.168.0.0/24}"
VPN_COUNTRIES="${VPN_COUNTRIES:-United States}"
UNAS_HOST="${UNAS_HOST:-192.168.0.111}"
UNAS_SHARE="${UNAS_SHARE:-jellyfish}"
MEDIA_MOUNT="${MEDIA_MOUNT:-/mnt/jellyfish}"

FORCE_ENV=0
SKIP_UP=0
for arg in "$@"; do
    case "$arg" in
        --force-env) FORCE_ENV=1 ;;
        --skip-up)   SKIP_UP=1 ;;
        -h|--help)   sed -n '2,30p' "$0"; exit 0 ;;
        *) echo "unknown flag: $arg" >&2; exit 2 ;;
    esac
done

log() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
die() { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || die "must run as root"
[ -f /etc/debian_version ] || die "expected Debian 12 (this is not a Debian system)"
[ -n "${WG_PRIVATE_KEY:-}" ] || die "WG_PRIVATE_KEY must be set"
[ -n "${WG_ADDRESSES:-}" ]   || die "WG_ADDRESSES must be set"
[ -n "${SMB_USERNAME:-}" ]   || die "SMB_USERNAME must be set"
[ -n "${SMB_PASSWORD:-}" ]   || die "SMB_PASSWORD must be set"

# ---------- 1. apt + base packages --------------------------------------------

log "updating apt and installing base packages"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y --no-install-recommends \
    ca-certificates curl gnupg lsb-release sudo \
    cifs-utils

# ---------- 2. docker engine + compose plugin ---------------------------------

if ! command -v docker >/dev/null 2>&1; then
    log "installing Docker Engine + compose plugin"
    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/debian/gpg \
        | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    chmod a+r /etc/apt/keyrings/docker.gpg

    codename="$(. /etc/os-release && echo "$VERSION_CODENAME")"
    cat > /etc/apt/sources.list.d/docker.list <<EOF
deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/debian ${codename} stable
EOF
    apt-get update -qq
    apt-get install -y --no-install-recommends \
        docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
    systemctl enable --now docker
else
    log "Docker already installed: $(docker --version)"
fi

# ---------- 3. stack user -----------------------------------------------------

if ! getent group "${STACK_GID}" >/dev/null 2>&1; then
    log "creating group ${STACK_USER} (gid ${STACK_GID})"
    groupadd --gid "${STACK_GID}" "${STACK_USER}"
fi
if ! id "${STACK_USER}" >/dev/null 2>&1; then
    log "creating user ${STACK_USER} (${STACK_UID}:${STACK_GID})"
    useradd --uid "${STACK_UID}" --gid "${STACK_GID}" \
            --create-home --shell /bin/bash "${STACK_USER}"
else
    log "reusing existing user ${STACK_USER} ($(id "${STACK_USER}"))"
fi
usermod -aG docker "${STACK_USER}"

# ---------- 4. CIFS mount to UNAS ---------------------------------------------

SMB_CRED="/etc/cifs-credentials.smb"
log "writing SMB credentials to ${SMB_CRED}"
umask 077
cat > "${SMB_CRED}" <<EOF
username=${SMB_USERNAME}
password=${SMB_PASSWORD}
EOF
chmod 0600 "${SMB_CRED}"

install -d -m 0755 "${MEDIA_MOUNT}"

FSTAB_LINE="//${UNAS_HOST}/${UNAS_SHARE}  ${MEDIA_MOUNT}  cifs  credentials=${SMB_CRED},uid=${STACK_UID},gid=${STACK_GID},iocharset=utf8,nofail,x-systemd.automount,_netdev  0  0"

if ! grep -qsF "${MEDIA_MOUNT}" /etc/fstab; then
    log "adding fstab entry for //${UNAS_HOST}/${UNAS_SHARE} → ${MEDIA_MOUNT}"
    printf '\n# UNAS jellyfish share (added by proxmox-scripts/arr-stack/provision.sh)\n%s\n' \
        "${FSTAB_LINE}" >> /etc/fstab
else
    log "fstab already contains an entry for ${MEDIA_MOUNT} — leaving it alone"
fi

log "mounting all"
systemctl daemon-reload
mount -a
mountpoint -q "${MEDIA_MOUNT}" \
    || die "${MEDIA_MOUNT} did not mount — check SMB creds and firewall rules"

# Create download landing dirs if missing. NEVER touch ownership of the
# existing Jellyfin tree — only chown what we create.
for sub in downloads downloads/incomplete downloads/complete; do
    if [ ! -d "${MEDIA_MOUNT}/${sub}" ]; then
        log "creating ${MEDIA_MOUNT}/${sub}"
        install -d -o "${STACK_UID}" -g "${STACK_GID}" "${MEDIA_MOUNT}/${sub}"
    fi
done

# ---------- 5. stack home + config tree ---------------------------------------

log "creating ${STACK_HOME} layout"
install -d -o "${STACK_USER}" -g "${STACK_USER}" "${STACK_HOME}"
install -d -o "${STACK_USER}" -g "${STACK_USER}" "${STACK_HOME}/config"
for svc in gluetun prowlarr radarr sonarr seerr qbittorrent qui profilarr; do
    install -d -o "${STACK_USER}" -g "${STACK_USER}" "${STACK_HOME}/config/${svc}"
done

# ---------- 6. drop compose.yaml + bind-mounted scripts -----------------------

# The host setup script SCPs compose.yaml + qbit-port-sync.sh into /root/
# before running this provision script. Move them into ${STACK_HOME} owned
# by the stack user. compose.yaml's bind mount `./qbit-port-sync.sh:…`
# resolves relative to ${STACK_HOME}, so the script MUST sit next to it.
if [ -f /root/compose.yaml ]; then
    log "installing compose.yaml at ${STACK_HOME}/compose.yaml"
    install -m 0644 -o "${STACK_USER}" -g "${STACK_USER}" \
        /root/compose.yaml "${STACK_HOME}/compose.yaml"
    rm -f /root/compose.yaml
elif [ ! -f "${STACK_HOME}/compose.yaml" ]; then
    die "compose.yaml missing — expected at /root/compose.yaml or ${STACK_HOME}/compose.yaml"
else
    log "compose.yaml already present at ${STACK_HOME}/compose.yaml"
fi

if [ -f /root/qbit-port-sync.sh ]; then
    log "installing qbit-port-sync.sh at ${STACK_HOME}/qbit-port-sync.sh"
    install -m 0755 -o "${STACK_USER}" -g "${STACK_USER}" \
        /root/qbit-port-sync.sh "${STACK_HOME}/qbit-port-sync.sh"
    rm -f /root/qbit-port-sync.sh
elif [ ! -f "${STACK_HOME}/qbit-port-sync.sh" ]; then
    die "qbit-port-sync.sh missing — expected at /root/qbit-port-sync.sh or ${STACK_HOME}/qbit-port-sync.sh"
else
    log "qbit-port-sync.sh already present at ${STACK_HOME}/qbit-port-sync.sh"
fi

# ---------- 7. write .env -----------------------------------------------------

ENV_PATH="${STACK_HOME}/.env"

if [ -f "${ENV_PATH}" ] && [ "${FORCE_ENV}" -ne 1 ]; then
    log "${ENV_PATH} already exists — skipping (pass --force-env to overwrite)"
else
    log "writing ${ENV_PATH}"
    umask 077
    cat > "${ENV_PATH}" <<EOF
# Generated by proxmox-scripts/arr-stack/provision.sh
TZ=${TZ}
LAN=${LAN}
CONFIG_PATH=${STACK_HOME}/config
MEDIA_PATH=${MEDIA_MOUNT}

# Gluetun / ProtonVPN — WireGuard config from account.protonvpn.com
WG_PRIVATE_KEY=${WG_PRIVATE_KEY}
WG_ADDRESSES=${WG_ADDRESSES}
VPN_COUNTRIES=${VPN_COUNTRIES}
EOF
    chown "${STACK_USER}:${STACK_USER}" "${ENV_PATH}"
    chmod 0600 "${ENV_PATH}"
fi

# ---------- 8. compose up -----------------------------------------------------

if [ "${SKIP_UP}" -eq 1 ]; then
    log "--skip-up set; not running docker compose"
    log "to start the stack manually:"
    log "  sudo -u ${STACK_USER} -- bash -lc 'cd ${STACK_HOME} && docker compose up -d'"
    exit 0
fi

log "pulling images (this can take a few minutes)"
sudo -u "${STACK_USER}" -- bash -lc \
    "cd '${STACK_HOME}' && docker compose pull"

log "starting gluetun first and waiting for the tunnel"
sudo -u "${STACK_USER}" -- bash -lc \
    "cd '${STACK_HOME}' && docker compose up -d gluetun"

# Wait up to ~90s for gluetun to report healthy. Use docker's healthcheck
# rather than log-grepping because gluetun's log strings change between
# releases; the healthcheck is the stable signal that the tunnel works.
for _ in $(seq 1 45); do
    health="$(docker inspect -f '{{.State.Health.Status}}' gluetun 2>/dev/null || true)"
    case "$health" in
        healthy)   log "gluetun: container healthy"; break ;;
        unhealthy) log "gluetun: container unhealthy — continuing, inspect with 'docker logs gluetun'"; break ;;
        *)         sleep 2 ;;
    esac
done

# Surface the ProtonVPN NAT-PMP forwarded port. This is what qBittorrent
# needs in Tools → Options → Connection → Port used for incoming connections.
fp_line="$(docker logs gluetun 2>&1 | grep -E '\[port forwarding\] port forwarded is' | tail -1 || true)"
if [ -n "$fp_line" ]; then
    fp_port="$(printf '%s\n' "$fp_line" | grep -oE '[0-9]+$' || true)"
    [ -n "$fp_port" ] && log "gluetun: forwarded port = ${fp_port} (paste into qBittorrent → Connection → Port)"
fi

log "starting the rest of the stack"
sudo -u "${STACK_USER}" -- bash -lc \
    "cd '${STACK_HOME}' && docker compose up -d"

log "done — container status:"
sudo -u "${STACK_USER}" -- bash -lc \
    "cd '${STACK_HOME}' && docker compose ps"

cat <<EOF

Next steps:
  - check the forwarded port:  docker logs gluetun | grep 'Port forwarded'
  - qbittorrent WebUI:         http://<vm-ip>:8080
  - prowlarr / radarr / sonarr / seerr UIs:  see README.md

EOF
