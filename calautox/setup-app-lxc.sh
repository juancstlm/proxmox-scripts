#!/usr/bin/env bash
# setup-app-lxc.sh
# ----------------
# Runs on the PROXMOX HOST. Creates an unprivileged Debian 12 LXC for the
# calautox app, configures a static IP on a user-supplied VLAN, then pushes
# provision.sh inside and runs it to install Docker, clone the repo, and
# bring up the compose stack.
#
# Picks the next available container ID via `pvesh get /cluster/nextid`.
# Prompts (with defaults) for everything else; env vars/flags override.
#
# Env vars (all optional except where noted):
#   CTID                 force a specific container ID instead of next-available
#   HOSTNAME             LXC hostname           (default: calautox-app)
#   VLAN_TAG             VLAN id for net0       — prompted if unset
#   IP_CIDR              static IP in CIDR form (e.g. 10.6.1.10/24) — prompted
#   GATEWAY              default gateway        — prompted, must reach VLAN
#   BRIDGE               Proxmox bridge         (default: vmbr0)
#   STORAGE              rootfs storage pool    (default: local-lvm)
#   TEMPLATE_STORAGE     where templates live   (default: local)
#   TEMPLATE             template volid or path (default: auto-detect debian-12)
#   CORES                cpu cores              (default: 2)
#   MEMORY               RAM MB                 (default: 2048)
#   DISK_GB              rootfs size in GB      (default: 8)
#   LXC_ROOT_PASSWORD    root password inside the LXC — prompted if unset
#   SSH_PUBLIC_KEY_FILE  path to authorized_keys to install (optional)
#   AUTOX_DB_HOST        DB host/IP the API will connect to — prompted if unset
#   AUTOX_DB_PASSWORD    forwarded to provision.sh — prompted if unset
#   PROVISION_URL        URL to fetch provision.sh from when not running from
#                        a git checkout (default: raw.githubusercontent.com…/main)
#
# All AUTOX_* / CALAUTOX_* env vars are forwarded to provision.sh.
#
# Flags:
#   --no-provision       create + start the LXC but skip running provision.sh
#   --force-env          forwarded to provision.sh
#   --skip-up            forwarded to provision.sh
#   -h|--help            show this header

set -euo pipefail

NO_PROVISION=0
PROVISION_FLAGS=()
for arg in "$@"; do
    case "$arg" in
        --no-provision) NO_PROVISION=1 ;;
        --force-env)    PROVISION_FLAGS+=("--force-env") ;;
        --skip-up)      PROVISION_FLAGS+=("--skip-up") ;;
        -h|--help)      sed -n '2,40p' "$0"; exit 0 ;;
        *) echo "unknown flag: $arg" >&2; exit 2 ;;
    esac
done

log() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
die() { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || die "must run as root on the Proxmox host"
command -v pct  >/dev/null 2>&1 || die "pct not found — is this a Proxmox VE host?"
command -v pvesh >/dev/null 2>&1 || die "pvesh not found — is this a Proxmox VE host?"

# ---------- helpers -----------------------------------------------------------

# prompt VAR "label" "default"  — reads from stdin, falls back to default
prompt() {
    local __varname="$1" __label="$2" __default="${3:-}"
    local __current="${!__varname:-}"
    if [ -n "$__current" ]; then return; fi
    local __input
    if [ -n "$__default" ]; then
        read -rp "${__label} [${__default}]: " __input || true
        printf -v "$__varname" '%s' "${__input:-$__default}"
    else
        read -rp "${__label}: " __input || true
        printf -v "$__varname" '%s' "$__input"
    fi
}

prompt_secret() {
    local __varname="$1" __label="$2"
    local __current="${!__varname:-}"
    if [ -n "$__current" ]; then return; fi
    local __input
    read -rsp "${__label}: " __input; echo
    printf -v "$__varname" '%s' "$__input"
}

# ---------- 1. collect inputs --------------------------------------------------

HOSTNAME="${HOSTNAME:-}"
BRIDGE="${BRIDGE:-}"
STORAGE="${STORAGE:-}"
TEMPLATE_STORAGE="${TEMPLATE_STORAGE:-local}"
CORES="${CORES:-}"
MEMORY="${MEMORY:-}"
DISK_GB="${DISK_GB:-}"

prompt HOSTNAME "Hostname"                     "calautox-app"
prompt BRIDGE   "Bridge"                       "vmbr0"
prompt VLAN_TAG "VLAN tag (e.g. 60 for DMZ)"   ""
[ -n "${VLAN_TAG:-}" ] || die "VLAN tag is required"
[[ "$VLAN_TAG" =~ ^[0-9]+$ ]] || die "VLAN tag must be numeric: '$VLAN_TAG'"

prompt IP_CIDR  "Static IP in CIDR (e.g. 10.6.1.10/24)" ""
[ -n "${IP_CIDR:-}" ] || die "IP/CIDR is required"
[[ "$IP_CIDR" == */* ]] || die "IP must be in CIDR form (e.g. 10.6.1.10/24): '$IP_CIDR'"

prompt GATEWAY  "Default gateway"              ""
[ -n "${GATEWAY:-}" ] || die "Gateway is required"

prompt STORAGE  "rootfs storage pool"          "local-lvm"
prompt CORES    "CPU cores"                    "2"
prompt MEMORY   "Memory (MB)"                  "2048"
prompt DISK_GB  "Disk size (GB)"               "8"

# Template: auto-detect a debian-12 standard template if not provided.
if [ -z "${TEMPLATE:-}" ]; then
    log "auto-detecting Debian 12 template in storage '${TEMPLATE_STORAGE}'"
    TEMPLATE="$(pveam list "${TEMPLATE_STORAGE}" 2>/dev/null \
        | awk 'NR>1 {print $1}' \
        | grep -E 'debian-12-standard_.*\.tar\.(zst|gz|xz)$' \
        | sort | tail -1 || true)"
    if [ -z "$TEMPLATE" ]; then
        log "no debian-12 template found; downloading the latest"
        pveam update >/dev/null
        latest="$(pveam available --section system \
            | awk '/debian-12-standard/ {print $2}' | sort | tail -1)"
        [ -n "$latest" ] || die "could not find a debian-12-standard template on the Proxmox mirror"
        pveam download "${TEMPLATE_STORAGE}" "$latest"
        TEMPLATE="${TEMPLATE_STORAGE}:vztmpl/${latest}"
    fi
    log "using template: ${TEMPLATE}"
fi

prompt AUTOX_DB_HOST "DB host/IP the API will connect to" ""
[ -n "${AUTOX_DB_HOST:-}" ] || die "AUTOX_DB_HOST is required"

prompt_secret LXC_ROOT_PASSWORD  "Root password for the new LXC"
[ -n "${LXC_ROOT_PASSWORD:-}" ] || die "LXC root password is required"

prompt_secret AUTOX_DB_PASSWORD  "Password for DB role 'autox_api'"
[ -n "${AUTOX_DB_PASSWORD:-}" ] || die "AUTOX_DB_PASSWORD is required"

# ---------- 2. next available CTID --------------------------------------------

if [ -z "${CTID:-}" ]; then
    CTID="$(pvesh get /cluster/nextid)"
fi
[[ "$CTID" =~ ^[0-9]+$ ]] || die "invalid CTID: '$CTID'"

if pct status "$CTID" >/dev/null 2>&1; then
    die "CTID ${CTID} already exists — pass CTID=<id> to use a specific free id"
fi

log "using CTID ${CTID}"

# ---------- 3. create the LXC -------------------------------------------------

log "creating LXC ${CTID} (${HOSTNAME}) on ${BRIDGE} tag=${VLAN_TAG} ip=${IP_CIDR}"

# net0: name=eth0,bridge=BRIDGE,ip=CIDR,gw=GATEWAY,tag=VLAN
net0_spec="name=eth0,bridge=${BRIDGE},ip=${IP_CIDR},gw=${GATEWAY},tag=${VLAN_TAG}"

ssh_key_args=()
if [ -n "${SSH_PUBLIC_KEY_FILE:-}" ]; then
    [ -r "$SSH_PUBLIC_KEY_FILE" ] || die "SSH_PUBLIC_KEY_FILE not readable: $SSH_PUBLIC_KEY_FILE"
    ssh_key_args=(--ssh-public-keys "$SSH_PUBLIC_KEY_FILE")
fi

pct create "$CTID" "$TEMPLATE" \
    --hostname    "$HOSTNAME" \
    --cores       "$CORES" \
    --memory      "$MEMORY" \
    --swap        512 \
    --rootfs      "${STORAGE}:${DISK_GB}" \
    --net0        "$net0_spec" \
    --features    nesting=1 \
    --unprivileged 1 \
    --onboot      1 \
    --ostype      debian \
    --password    "$LXC_ROOT_PASSWORD" \
    "${ssh_key_args[@]}"

# ---------- 4. start and wait for network -------------------------------------

log "starting LXC ${CTID}"
pct start "$CTID"

log "waiting for network inside the container"
for _ in $(seq 1 30); do
    if pct exec "$CTID" -- sh -c 'getent hosts deb.debian.org >/dev/null 2>&1'; then
        break
    fi
    sleep 2
done
pct exec "$CTID" -- sh -c 'getent hosts deb.debian.org >/dev/null' \
    || die "container has no network connectivity — check VLAN ${VLAN_TAG} / gateway ${GATEWAY}"

if [ "$NO_PROVISION" -eq 1 ]; then
    log "--no-provision set; container is up but unprovisioned"
    log "to provision later, run:"
    log "  AUTOX_DB_PASSWORD=… ./$(basename "$0")  (re-run with CTID=${CTID})"
    exit 0
fi

# ---------- 5. push provision.sh and run it -----------------------------------

PROVISION_URL="${PROVISION_URL:-https://raw.githubusercontent.com/juancstlm/proxmox-scripts/main/calautox/provision.sh}"

# Try alongside this script first (git checkout); otherwise download.
provision_local=""
self_src="${BASH_SOURCE[0]:-}"
if [ -n "$self_src" ] && [ -f "$self_src" ]; then
    candidate="$(cd -- "$(dirname -- "$self_src")" && pwd)/provision.sh"
    [ -r "$candidate" ] && provision_local="$candidate"
fi
if [ -z "$provision_local" ]; then
    provision_local="$(mktemp -t provision.XXXXXX.sh)"
    trap 'rm -f "$provision_local"' EXIT
    log "fetching provision.sh from ${PROVISION_URL}"
    curl -fsSL "$PROVISION_URL" -o "$provision_local" \
        || die "failed to fetch provision.sh from ${PROVISION_URL}"
    chmod +x "$provision_local"
fi

log "pushing provision.sh into LXC ${CTID}"
pct push "$CTID" "$provision_local" /root/provision.sh --perms 0755

log "running provision.sh inside LXC ${CTID}"
# Forward env vars by exporting them in the in-container shell.
pct exec "$CTID" -- env \
    AUTOX_DB_PASSWORD="$AUTOX_DB_PASSWORD" \
    AUTOX_DB_HOST="${AUTOX_DB_HOST:-}" \
    AUTOX_DB_PORT="${AUTOX_DB_PORT:-}" \
    AUTOX_DB_NAME="${AUTOX_DB_NAME:-}" \
    AUTOX_DB_USER="${AUTOX_DB_USER:-}" \
    API_LISTEN="${API_LISTEN:-}" \
    CALAUTOX_REPO_URL="${CALAUTOX_REPO_URL:-}" \
    CALAUTOX_REPO_REF="${CALAUTOX_REPO_REF:-}" \
    DEPLOY_USER="${DEPLOY_USER:-}" \
    CALAUTOX_HOME="${CALAUTOX_HOME:-}" \
    /root/provision.sh "${PROVISION_FLAGS[@]}"

log "all done"
log "  CTID:     ${CTID}"
log "  hostname: ${HOSTNAME}"
log "  ip:       ${IP_CIDR} (vlan ${VLAN_TAG}, via ${GATEWAY})"
log "  shell in: pct enter ${CTID}"
