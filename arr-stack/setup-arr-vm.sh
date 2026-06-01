#!/usr/bin/env bash
# setup-arr-vm.sh
# ---------------
# Runs on the PROXMOX HOST. Creates a Debian 12 cloud-image VM for the
# arr-stack docker compose. Tags net0 with the Apps VLAN (81 by default),
# configures cloud-init with a static IP, then SSHes in and runs
# provision.sh to install Docker, mount the UNAS share, and bring up the
# compose stack.
#
# Why a VM (not LXC): the qBittorrent traffic tunnels through gluetun, which
# needs /dev/net/tun and CAP_NET_ADMIN. A VM gets that for free.
#
# Picks the next available VMID via `pvesh get /cluster/nextid` unless one
# is forced.
#
# Env vars (all optional except where noted):
#   VMID                 force a specific VM ID instead of next-available
#   VM_HOSTNAME          VM hostname            (default: arr-stack)
#   IP_CIDR              static IP in CIDR form
#                        (default: derived from VMID — e.g. VMID 114 → 10.8.1.114/24)
#   GATEWAY              default gateway        (default: 10.8.1.1)
#   DNS_SERVERS          space-sep list         (default: "192.168.0.124 192.168.0.23")
#   BRIDGE               Proxmox bridge         (default: vmbr0)
#   VLAN_TAG             802.1Q VLAN tag for net0 — the Apps VLAN ID
#                        (default: 81)
#   STORAGE              rootfs storage pool — prompted if unset, with a list
#                        of available image-capable pools and a smart default
#                        (prefers `nvme`, then first non-`local`)
#   TEMPLATE_STORAGE     where templates live   (default: local)
#   CLOUD_IMG_PATH       path on host to debian-12 genericcloud qcow2
#                        (default: /var/lib/vz/template/iso/debian-12-genericcloud-amd64.qcow2)
#   CLOUD_IMG_URL        download URL if missing
#                        (default: cloud.debian.org bookworm latest genericcloud)
#   CORES                cpu cores              (default: 3)
#   MEMORY               RAM MB                 (default: 6144)
#   DISK_GB              rootfs size in GB      (default: 32)
#   CI_USER              cloud-init user        (default: juanc)
#   CI_PASSWORD          cloud-init password    — prompted if unset
#   SSH_PUBLIC_KEY_FILE  pub key for ci user    (default: ~/.ssh/id_ed25519.pub or id_rsa.pub)
#   SSH_PRIVATE_KEY_FILE matching priv key      (auto-derived from .pub by stripping `.pub`)
#
#   (All optional env vars forwarded to provision.sh — see its header.)
#   Required at provision time (will be prompted if unset):
#     WG_PRIVATE_KEY     ProtonVPN WireGuard private key
#     WG_ADDRESSES       WG client address (default: 10.2.0.2/32)
#     SMB_USERNAME       UNAS SMB user with read+write on jellyfish
#     SMB_PASSWORD       password for that user
#
# Flags:
#   --no-provision       create + start the VM but skip running provision.sh
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
        -h|--help)      sed -n '2,50p' "$0"; exit 0 ;;
        *) echo "unknown flag: $arg" >&2; exit 2 ;;
    esac
done

log() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
die() { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || die "must run as root on the Proxmox host"
command -v qm    >/dev/null 2>&1 || die "qm not found — is this a Proxmox VE host?"
command -v pvesh >/dev/null 2>&1 || die "pvesh not found — is this a Proxmox VE host?"
command -v ssh   >/dev/null 2>&1 || die "ssh missing on the Proxmox host"
command -v scp   >/dev/null 2>&1 || die "scp missing on the Proxmox host"

# ---------- helpers -----------------------------------------------------------

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

VM_HOSTNAME="${VM_HOSTNAME:-arr-stack}"
BRIDGE="${BRIDGE:-vmbr0}"
VLAN_TAG="${VLAN_TAG:-81}"
TEMPLATE_STORAGE="${TEMPLATE_STORAGE:-local}"

# Storage pool for the VM disk. List active image-capable pools and let the
# user pick; default to `nvme` if it exists, else the first non-`local` pool.
available_storage="$(pvesm status -content images 2>/dev/null | awk 'NR>1 && $3=="active" {print $1}')"
[ -n "$available_storage" ] \
    || die "no active image-capable storage pools found (pvesm status -content images returned nothing)"

if [ -z "${STORAGE:-}" ]; then
    default_storage="$(printf '%s\n' $available_storage | grep -m1 '^nvme$' || true)"
    [ -n "$default_storage" ] \
        || default_storage="$(printf '%s\n' $available_storage | grep -m1 -v '^local$' | head -1 || true)"
    [ -n "$default_storage" ] \
        || default_storage="$(printf '%s\n' $available_storage | head -1)"

    echo "Available storage pools for VM disks:"
    printf '  - %s\n' $available_storage
    prompt STORAGE "Storage pool for VM disk" "$default_storage"
fi

printf '%s\n' $available_storage | grep -qxF "$STORAGE" \
    || die "storage '$STORAGE' is not an active image-capable pool. Available: $(echo $available_storage | tr '\n' ' ')"
CORES="${CORES:-3}"
MEMORY="${MEMORY:-6144}"
DISK_GB="${DISK_GB:-32}"

# IP_CIDR is derived from VMID after VMID is determined (see below).
# Override by exporting IP_CIDR= explicitly.
GATEWAY="${GATEWAY:-10.8.1.1}"
DNS_SERVERS="${DNS_SERVERS:-192.168.0.124 192.168.0.23}"

CI_USER="${CI_USER:-juanc}"

CLOUD_IMG_URL="${CLOUD_IMG_URL:-https://cloud.debian.org/images/cloud/bookworm/latest/debian-12-genericcloud-amd64.qcow2}"
CLOUD_IMG_PATH="${CLOUD_IMG_PATH:-/var/lib/vz/template/iso/debian-12-genericcloud-amd64.qcow2}"

# SSH keys — used for both cloud-init seeding and the later provision SSH.
if [ -z "${SSH_PUBLIC_KEY_FILE:-}" ]; then
    for cand in "${HOME}/.ssh/id_ed25519.pub" "${HOME}/.ssh/id_rsa.pub"; do
        if [ -r "$cand" ]; then SSH_PUBLIC_KEY_FILE="$cand"; break; fi
    done
fi
[ -n "${SSH_PUBLIC_KEY_FILE:-}" ] && [ -r "$SSH_PUBLIC_KEY_FILE" ] \
    || die "no SSH public key found — set SSH_PUBLIC_KEY_FILE to an .pub file readable by root"

if [ -z "${SSH_PRIVATE_KEY_FILE:-}" ]; then
    SSH_PRIVATE_KEY_FILE="${SSH_PUBLIC_KEY_FILE%.pub}"
fi
[ -r "$SSH_PRIVATE_KEY_FILE" ] \
    || die "matching private key not readable at ${SSH_PRIVATE_KEY_FILE} (override with SSH_PRIVATE_KEY_FILE=)"

prompt_secret CI_PASSWORD "cloud-init password for user '${CI_USER}' (also used for console fallback)"
[ -n "${CI_PASSWORD:-}" ] || die "CI_PASSWORD is required"

# Provision-time inputs — collect now so the host script doesn't pause halfway.
if [ "$NO_PROVISION" -ne 1 ]; then
    prompt SMB_USERNAME "UNAS SMB username (read+write on jellyfish share)" ""
    [ -n "${SMB_USERNAME:-}" ] || die "SMB_USERNAME is required"
    prompt_secret SMB_PASSWORD "UNAS SMB password"
    [ -n "${SMB_PASSWORD:-}" ] || die "SMB_PASSWORD is required"

    prompt WG_ADDRESSES "ProtonVPN WireGuard client address (CIDR)" "10.2.0.2/32"
    prompt_secret WG_PRIVATE_KEY "ProtonVPN WireGuard private key (from .conf)"
    [ -n "${WG_PRIVATE_KEY:-}" ] || die "WG_PRIVATE_KEY is required"
fi

# ---------- 2. ensure cloud image is present ----------------------------------

if [ ! -f "$CLOUD_IMG_PATH" ]; then
    log "downloading Debian 12 cloud image → ${CLOUD_IMG_PATH}"
    install -d -m 0755 "$(dirname "$CLOUD_IMG_PATH")"
    curl -fSL "$CLOUD_IMG_URL" -o "$CLOUD_IMG_PATH" \
        || die "failed to download ${CLOUD_IMG_URL}"
else
    log "cloud image already present: $CLOUD_IMG_PATH"
fi

# ---------- 3. next available VMID --------------------------------------------

if [ -z "${VMID:-}" ]; then
    VMID="$(pvesh get /cluster/nextid)"
fi
[[ "$VMID" =~ ^[0-9]+$ ]] || die "invalid VMID: '$VMID'"

if qm status "$VMID" >/dev/null 2>&1; then
    die "VMID ${VMID} already exists — pass VMID=<id> to use a specific free id"
fi

log "using VMID ${VMID}"

# Derive static IP from VMID unless one was explicitly provided. Convention:
# 10.8.1.<VMID> — VMID 114 → 10.8.1.114. This keeps "what host is .114?" easy
# to answer from either the Proxmox UI or the Apps VLAN DHCP table.
if [ -z "${IP_CIDR:-}" ]; then
    if [ "$VMID" -lt 2 ] || [ "$VMID" -gt 254 ]; then
        die "VMID ${VMID} can't map to a valid last octet (need 2–254). Pass IP_CIDR= to override."
    fi
    IP_CIDR="10.8.1.${VMID}/24"
    log "derived IP_CIDR=${IP_CIDR} from VMID ${VMID}"
fi
[[ "$IP_CIDR" == */* ]] || die "IP_CIDR must be in CIDR form (e.g. 10.8.1.114/24): '$IP_CIDR'"

# ---------- 4. create the VM --------------------------------------------------

log "creating VM ${VMID} (${VM_HOSTNAME}) on ${BRIDGE}, ip=${IP_CIDR} gw=${GATEWAY}"

qm create "$VMID" \
    --name        "$VM_HOSTNAME" \
    --cores       "$CORES" \
    --memory      "$MEMORY" \
    --net0        "virtio,bridge=${BRIDGE},tag=${VLAN_TAG}" \
    --serial0     socket \
    --agent       1 \
    --ostype      l26 \
    --onboot      1

# Import the cloud image as scsi0, resize, set boot order, add cloud-init drive.
log "importing cloud image to ${STORAGE}"
qm importdisk "$VMID" "$CLOUD_IMG_PATH" "$STORAGE" >/dev/null

# importdisk leaves the disk "unused0"; attach it as scsi0.
unused="$(qm config "$VMID" | awk -F': ' '/^unused0:/ {print $2; exit}')"
[ -n "$unused" ] || die "could not find unused0 disk after importdisk"

qm set "$VMID" \
    --scsihw    virtio-scsi-pci \
    --scsi0     "${unused},discard=on,ssd=1" >/dev/null
qm resize "$VMID" scsi0 "${DISK_GB}G" >/dev/null
qm set "$VMID" \
    --ide2      "${STORAGE}:cloudinit" \
    --boot      order=scsi0 >/dev/null

# Cloud-init config.
qm set "$VMID" \
    --ciuser      "$CI_USER" \
    --cipassword  "$CI_PASSWORD" \
    --sshkeys     "$SSH_PUBLIC_KEY_FILE" \
    --ipconfig0   "ip=${IP_CIDR},gw=${GATEWAY}" \
    --nameserver  "$DNS_SERVERS" \
    --searchdomain "longdog.racing" >/dev/null

# ---------- 5. print MAC + pause for UniFi override ---------------------------

VM_MAC="$(qm config "$VMID" | awk -F'=|,' '/^net0:/ {for (i=1;i<=NF;i++) if ($i ~ /^[0-9A-Fa-f:]{17}$/) {print $i; exit}}')"
[ -n "$VM_MAC" ] || die "could not determine VM MAC address"

VM_IP="${IP_CIDR%/*}"

cat <<EOF

════════════════════════════════════════════════════════════════════════
  Pause here. Verify in UniFi before starting the VM:

    1.  CGF Port 1 (the port carrying PVE's nic0 trunk) must allow
        VLAN ${VLAN_TAG} in its port profile / allowed-networks list.
        The VM tags its own frames at VLAN ${VLAN_TAG}; if the port
        strips that tag, you'll see Default-VLAN behavior again.

    2.  Optional — pre-register the client for visibility:
        Clients → Add Client (or wait for it to appear after first boot)
           MAC:      ${VM_MAC}
           Fixed IP: ${VM_IP}

        Tagged-at-PVE means UniFi WILL put it on the Apps network
        without any Virtual Network Override toggle.

    3.  Confirm the firewall rules from Arr Stack.md are in place:
          Apps → AdGuard, pihole, UNAS SMB, Jellyfin (CT 105)
          + the Apps zone-matrix defaults.
════════════════════════════════════════════════════════════════════════

EOF

read -rp "  Press Enter when UniFi is ready… " _

# ---------- 6. start the VM and wait for SSH ----------------------------------

log "starting VM ${VMID}"
qm start "$VMID"

log "waiting for SSH on ${VM_IP}:22 (up to 5 min)"
SSH_OPTS=(-o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=/dev/null -o ConnectTimeout=5 -i "$SSH_PRIVATE_KEY_FILE")
ssh_ready=0
for _ in $(seq 1 60); do
    if ssh "${SSH_OPTS[@]}" -o BatchMode=yes "${CI_USER}@${VM_IP}" true 2>/dev/null; then
        ssh_ready=1; break
    fi
    sleep 5
done
[ "$ssh_ready" -eq 1 ] || die "SSH never came up at ${CI_USER}@${VM_IP} — check the UniFi override and console"

log "SSH is up — sudo-ing in as root for provisioning"

if [ "$NO_PROVISION" -eq 1 ]; then
    log "--no-provision set; VM is up but unprovisioned"
    log "to provision later: re-run this script with VMID=${VMID}"
    exit 0
fi

# ---------- 7. push provision.sh + compose.yaml, run it -----------------------

# Resolve sibling files (provision.sh + compose.yaml + qbit-port-sync.sh)
# from this script's directory. If running via curl-pipe, fall back to
# fetching from the repo.
PROVISION_URL="${PROVISION_URL:-https://raw.githubusercontent.com/juancstlm/proxmox-scripts/main/arr-stack/provision.sh}"
COMPOSE_URL="${COMPOSE_URL:-https://raw.githubusercontent.com/juancstlm/proxmox-scripts/main/arr-stack/compose.yaml}"
PORT_SYNC_URL="${PORT_SYNC_URL:-https://raw.githubusercontent.com/juancstlm/proxmox-scripts/main/arr-stack/qbit-port-sync.sh}"

self_dir=""
self_src="${BASH_SOURCE[0]:-}"
if [ -n "$self_src" ] && [ -f "$self_src" ]; then
    self_dir="$(cd -- "$(dirname -- "$self_src")" && pwd)"
fi

provision_local=""
compose_local=""
port_sync_local=""
cleanup_tmp() {
    [ -n "${provision_tmp:-}" ] && rm -f "$provision_tmp"
    [ -n "${compose_tmp:-}" ] && rm -f "$compose_tmp"
    [ -n "${port_sync_tmp:-}" ] && rm -f "$port_sync_tmp"
}
trap cleanup_tmp EXIT

if [ -n "$self_dir" ] && [ -r "${self_dir}/provision.sh" ]; then
    provision_local="${self_dir}/provision.sh"
else
    provision_tmp="$(mktemp -t arr-provision.XXXXXX.sh)"
    log "fetching provision.sh from ${PROVISION_URL}"
    curl -fsSL "$PROVISION_URL" -o "$provision_tmp" \
        || die "failed to fetch provision.sh"
    provision_local="$provision_tmp"
fi

if [ -n "$self_dir" ] && [ -r "${self_dir}/compose.yaml" ]; then
    compose_local="${self_dir}/compose.yaml"
else
    compose_tmp="$(mktemp -t arr-compose.XXXXXX.yaml)"
    log "fetching compose.yaml from ${COMPOSE_URL}"
    curl -fsSL "$COMPOSE_URL" -o "$compose_tmp" \
        || die "failed to fetch compose.yaml"
    compose_local="$compose_tmp"
fi

if [ -n "$self_dir" ] && [ -r "${self_dir}/qbit-port-sync.sh" ]; then
    port_sync_local="${self_dir}/qbit-port-sync.sh"
else
    port_sync_tmp="$(mktemp -t arr-port-sync.XXXXXX.sh)"
    log "fetching qbit-port-sync.sh from ${PORT_SYNC_URL}"
    curl -fsSL "$PORT_SYNC_URL" -o "$port_sync_tmp" \
        || die "failed to fetch qbit-port-sync.sh"
    port_sync_local="$port_sync_tmp"
fi

log "scp'ing provision.sh + compose.yaml + qbit-port-sync.sh to ${CI_USER}@${VM_IP}:/tmp/"
# Use explicit destination filenames so the remote side gets predictable
# paths regardless of whether the local source was a sibling file or a
# mktemp tempfile (which has a random basename).
scp "${SSH_OPTS[@]}" "$provision_local" "${CI_USER}@${VM_IP}:/tmp/provision.sh"
scp "${SSH_OPTS[@]}" "$compose_local"   "${CI_USER}@${VM_IP}:/tmp/compose.yaml"
scp "${SSH_OPTS[@]}" "$port_sync_local" "${CI_USER}@${VM_IP}:/tmp/qbit-port-sync.sh"

log "running provision.sh as root inside the VM"
# Forward env vars over SSH. Secrets are passed via env, not on the command
# line, so they don't appear in the remote `ps`.
ssh "${SSH_OPTS[@]}" "${CI_USER}@${VM_IP}" "\
    sudo install -m 0644 /tmp/compose.yaml         /root/compose.yaml && \
    sudo install -m 0755 /tmp/provision.sh         /root/provision.sh && \
    sudo install -m 0755 /tmp/qbit-port-sync.sh    /root/qbit-port-sync.sh && \
    rm -f /tmp/provision.sh /tmp/compose.yaml /tmp/qbit-port-sync.sh && \
    sudo env \
        WG_PRIVATE_KEY=$(printf %q "$WG_PRIVATE_KEY") \
        WG_ADDRESSES=$(printf %q "$WG_ADDRESSES") \
        SMB_USERNAME=$(printf %q "$SMB_USERNAME") \
        SMB_PASSWORD=$(printf %q "$SMB_PASSWORD") \
        TZ=$(printf %q "${TZ:-America/Los_Angeles}") \
        VPN_COUNTRIES=$(printf %q "${VPN_COUNTRIES:-United States}") \
        /root/provision.sh ${PROVISION_FLAGS[*]}\
"

log "all done"
log "  VMID:     ${VMID}"
log "  hostname: ${VM_HOSTNAME}"
log "  ip:       ${VM_IP} (Apps VLAN, via ${GATEWAY})"
log "  shell in: ssh ${CI_USER}@${VM_IP}"
log "  next:     add the nine *.longdog.racing caddy entries from Arr Stack.md"
