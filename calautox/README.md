# calautox app LXC

Bootstraps the [calautox](https://github.com/juancstlm/calautox) app LXC. The
LXC reverse-proxies through Caddy to the Go API + React SPA and reaches the
DB (on a separate Services VLAN) over a firewall pinhole on tcp/5432.

The flow has two scripts:

| Script | Where it runs | What it does |
| --- | --- | --- |
| `setup-app-lxc.sh` | Proxmox **host** | Picks the next available CTID, prompts for VLAN tag / static IP / gateway, creates an unprivileged Debian 12 LXC with those network settings, then pushes and runs `provision.sh` inside. |
| `provision.sh`     | **inside** the LXC | Installs Docker + compose plugin, creates the `deploy` user, clones the repo, writes `deploy/.env`, and runs `docker compose up -d --build`. |

You normally only invoke `setup-app-lxc.sh`. It runs `provision.sh`
automatically over `pct push` / `pct exec`.

## Usage

From a shell on the Proxmox host, as root:

```sh
bash -c "$(curl -fsSL https://raw.githubusercontent.com/juancstlm/proxmox-scripts/main/calautox/setup-app-lxc.sh)"
```

(If you'd rather inspect the script first — and you should — clone the repo
and run `./calautox/setup-app-lxc.sh` from there. The one-liner is provided
for parity with the community Proxmox scripts.)

The script will prompt for:

- **Hostname** (default `calautox-prod`)
- **Bridge** (default `vmbr0`)
- **VLAN tag** — e.g. `60` for the DMZ "Public Servers" network (no default)
- **Static IP in CIDR** — e.g. `10.6.1.10/24` (no default)
- **Default gateway** — e.g. `10.6.1.1` (no default)
- **rootfs storage pool**, CPU cores, RAM, disk size (defaults: `local-lvm`, 2 cores, 2048 MB, 8 GB)
- **DB host/IP** the API will connect to (no default — your Postgres LXC's address on the Services VLAN)
- **Path to an existing GitHub deploy key** (SSH private key) on the
  Proxmox host. Leave blank to have the script **generate a fresh ed25519
  keypair** for you (at `~/.ssh/${HOSTNAME}_github_deploy`), print the
  public half, and pause so you can paste it into the repo's
  Settings → Deploy keys page before continuing. Pass `none` to skip
  deploy-key handling entirely and use HTTPS via `CALAUTOX_REPO_URL`.
- **Root password for the new LXC** (prompted silently)
- **Password for DB role `autox_api`** (prompted silently, written to `deploy/.env` inside the LXC)

Any prompt can be skipped by exporting the corresponding env var first — see
the header of `setup-app-lxc.sh` for the full list.

The CTID is chosen automatically via `pvesh get /cluster/nextid`. Pass
`CTID=<id>` to override.

If no Debian 12 template is present on the configured storage, the script
runs `pveam download` to fetch one.

## GitHub deploy key handling

The default flow generates the deploy key for you:

1. `ssh-keygen -t ed25519` runs on the Proxmox host, dropping the keypair at
   `~/.ssh/${HOSTNAME}_github_deploy{,.pub}` (re-used on subsequent runs).
2. The script prints the **public** half and the direct link to the repo's
   "Add deploy key" page, then waits for you to press Enter once the key is
   added to GitHub. Read-only access is sufficient.
3. The private key is `pct push`ed into the LXC, installed under
   `~deploy/.ssh/calautox_deploy_key`, and the staging copy is `shred`ded.
4. GitHub's host key is scanned into the deploy user's `known_hosts` so the
   first `git clone` doesn't hang on a yes/no prompt.

If you already have a deploy key (e.g. one you keep in a password manager),
point the prompt at its private-key file on the Proxmox host instead.

## Useful flags

- `--no-provision` — create and start the LXC but skip `provision.sh` (handy
  if you want to inspect / customize before bringing the stack up).
- `--force-env` — overwrite an existing `deploy/.env` inside the LXC.
- `--skip-up` — provision everything but don't run `docker compose up`.

## After it finishes

```sh
pct enter <CTID>            # shell into the LXC
docker compose -f /home/deploy/calautox/deploy/docker-compose.yml ps
docker compose -f /home/deploy/calautox/deploy/docker-compose.yml logs api
```

Caddy listens on the LXC's static IP, port 80. Point your upstream reverse
proxy or public DNS at it.

## What the script deliberately does NOT do

- Open firewall ports on the Proxmox host or UniFi gateway — pinholes are
  managed in the UniFi zone-based firewall (DMZ → Services tcp/5432).
- Install a TLS certificate — Caddy can do this itself once the LXC has a
  public hostname; until then it serves plain HTTP on :80.
- Configure unattended-upgrades or other host-level hardening.
