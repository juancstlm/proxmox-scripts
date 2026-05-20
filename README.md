# proxmox-scripts

Setup scripts I use to bootstrap LXC containers on my Proxmox host. Each
subdirectory targets one private project; the scripts themselves are public
and never contain secrets (passwords, keys, internal IPs that aren't already
documented).

## Layout

```
proxmox-scripts/
└── calautox/
    └── setup-app-lxc.sh    # bootstraps the calautox app LXC (DMZ / Public Servers)
```

## Conventions

- Scripts target a freshly-created **Debian 12** LXC (the default Proxmox
  template).
- Run them as root inside the LXC, e.g.:
  ```sh
  curl -fsSL https://raw.githubusercontent.com/juancstlm/proxmox-scripts/main/<path>/setup.sh | bash
  ```
- Anything that requires a secret (DB password, deploy key) is taken from an
  environment variable or prompted for at runtime — never baked into the
  script.
- Scripts should be idempotent: re-running on a half-configured LXC should
  converge to the same end state, not error out.
