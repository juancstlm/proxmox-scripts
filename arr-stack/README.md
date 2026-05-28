# arr-stack VM

Bootstraps a Debian 12 cloud-image **VM** (not LXC) on Proxmox that hosts
the arr-stack docker compose: prowlarr, radarr, sonarr, seerr,
qbittorrent-behind-gluetun-ProtonVPN, qui, profilarr, flaresolverr,
watchtower, dozzle.

A VM rather than an LXC because qBittorrent tunnels through gluetun, which
needs `/dev/net/tun` and `CAP_NET_ADMIN`. Plain VM, no LXC tweaks needed.

See `vault/Homelab/Arr Stack.md` for the full design and the Topology
implications.

## Files

| File            | Where it runs            | What it does |
| --------------- | ------------------------ | --- |
| `setup-arr-vm.sh` | Proxmox **host**       | Picks next VMID, downloads the Debian 12 cloud image if missing, creates the VM with `net0 tag=81` (Apps VLAN) and cloud-init (static IP derived from VMID — `10.8.1.<VMID>/24`, SSH key seeded), prints the VM's MAC and pauses for UniFi sanity checks, then SSHes in and runs `provision.sh`. |
| `provision.sh`  | **inside** the VM       | Installs Docker + compose plugin, mounts the UNAS `jellyfish` share via CIFS at `/mnt/jellyfish`, drops `compose.yaml` and `.env` under `/opt/arr-stack/`, and brings the stack up. |
| `compose.yaml`  | **inside** the VM       | The compose file itself. SCP'd to `/root/compose.yaml`, then installed by `provision.sh` into `/opt/arr-stack/compose.yaml`. |

You normally only invoke `setup-arr-vm.sh`. It pushes the other two over
SSH automatically.

## Prerequisites

Before running the script, the **UniFi side** has to be ready:

1. **Apps network** created (`10.8.1.0/24`, VLAN 81, DHCP `.100–.199`,
   DNS `192.168.0.124` / `192.168.0.23`).
2. **Apps zone** created and the Apps network moved into it.
3. **Zone matrix** for Apps: `Apps → External / Gateway / Apps = Allow`,
   everything else `Block All`; `Internal → Apps = Allow All`,
   `External → Apps = Allow Return`.
4. **Four override policies**: `Apps → AdGuard DNS`, `Apps → pihole DNS`,
   `Apps → UNAS SMB` (TCP 139,445 to `192.168.0.111/32`),
   `Apps → Jellyfin (CT 105)` (TCP 8096 to `192.168.0.28/32`).

The script pauses after creating the VM to remind you that **CGF Port 1's
port profile must allow VLAN 81** so the tagged frames from the VM reach
the Apps network. PVE's `vmbr0` isn't VLAN-aware, but Linux bridges
forward tagged frames transparently — the tag is set per-guest in net0
(`tag=81`) and the CGF treats Port 1 as an 802.1Q trunk. No UniFi
per-MAC override is required.

You'll also want:

- A **ProtonVPN Plus/Unlimited** WireGuard config from
  `account.protonvpn.com → Downloads → WireGuard` with NAT-PMP enabled.
  Copy the `PrivateKey` and `Address` lines.
- An SMB user on the UNAS with read+write on the `jellyfish` share.

## Usage

From a shell on the Proxmox host, as root:

```sh
bash -c "$(curl -fsSL https://raw.githubusercontent.com/juancstlm/proxmox-scripts/main/arr-stack/setup-arr-vm.sh)"
```

Or from a local checkout:

```sh
cd /opt/proxmox-scripts/arr-stack
./setup-arr-vm.sh
```

The script will prompt for:

- **cloud-init password** for the user inside the VM (silent)
- **SMB username + password** for the UNAS share (silent password)
- **ProtonVPN WireGuard** client address (default `10.2.0.2/32`) and
  **private key** (silent)

Everything else has a sensible default — see the header of
`setup-arr-vm.sh` for the full list of env vars that override prompts.

The VMID is chosen via `pvesh get /cluster/nextid`. Pass `VMID=114` to
pin it to the planned ID. The static IP is then derived from the VMID:
`10.8.1.<VMID>/24` (so VMID 114 → 10.8.1.114). Override with
`IP_CIDR=10.8.1.200/24` etc. if you don't want the convention.

## Useful flags

- `--no-provision` — create + start the VM, skip the provisioning step.
  Useful if you want to inspect the VM before the stack comes up.
- `--force-env` — overwrite an existing `/opt/arr-stack/.env` inside the VM.
- `--skip-up` — install everything but don't run `docker compose up`.

## After it finishes

```sh
ssh juanc@10.8.1.114

# inside the VM
sudo docker compose -f /opt/arr-stack/compose.yaml ps
sudo docker logs gluetun 2>&1 | grep -E '\[port forwarding\] port forwarded is'
```

The forwarded port from ProtonVPN's NAT-PMP shows up in the gluetun logs
after the tunnel comes up — provision.sh also echoes it at the end of its
run. Paste it into qBittorrent → Tools → Options → Connection → Port
used for incoming connections, or wire up `gluetun-qbittorrent-port-manager`
as a sidecar (see Arr Stack.md).

Then in caddy (CT 113), add the eight `*.longdog.racing` reverse-proxy
entries listed at the bottom of `Topology.md` / `Arr Stack.md`.

## What the script deliberately does NOT do

- **Create the Apps VLAN, zone, or firewall rules** — those live in UniFi
  and are documented in `vault/Homelab/Arr Stack.md`. The VM is useless
  without them.
- **Add caddy entries** — the caddy config is hand-maintained on CT 113.
- **Migrate the existing Jellyfin (CT 105) install** — CT 105 keeps
  running natively. The *arr containers write to the same `jellyfish`
  share CT 105 reads.
- **Configure ProtonVPN port-forward auto-sync to qBittorrent** — see the
  manual vs sidecar discussion in Arr Stack.md.

## Idempotency notes

- `setup-arr-vm.sh` won't reuse an existing VMID — pass a free `VMID=` if
  you need to recreate.
- `provision.sh` is safe to re-run: docker install, user creation, CIFS
  mount, and compose dir creation all check for the existing state before
  acting. The `.env` will be left alone unless `--force-env` is passed.
