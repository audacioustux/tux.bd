# tux.bd — NixOS Home Server Config

Declarative NixOS configuration for a laptop-repurposed home server running at `tux.bd`.
Everything is reproducible: boot, filesystem, networking, services, backups, and the Docker infra stack are all defined in code.

---

## What's Inside

```
tux.bd/
├── nixos/
│   ├── configuration.nix          # Main NixOS config (the heart of everything)
│   ├── hardware-configuration.nix # Auto-generated hardware + ZFS filesystem layout
│   ├── hardware.local.nix.example # Template for disk UUIDs (gitignored on real machine)
│   ├── machine.local.nix.example  # Template for hashed password (gitignored)
│   └── POST-BOOT.md               # Step-by-step checklist after first boot
├── compose/
│   └── infra/
│       └── docker-compose.yml     # Traefik v3 reverse proxy + Portainer
└── secrets.examples/
    ├── garage.secrets.env.example # Template for Garage S3 credentials
    └── traefik.secrets.env.example# Template for Cloudflare DNS API token
```

---

## Stack at a Glance

| Layer | Technology |
|---|---|
| OS | NixOS 25.11 |
| Filesystem | ZFS (rpool) — encrypted, snapshotted, scrubbed |
| Bootloader | systemd-boot (EFI), latest Linux kernel |
| Reverse proxy | Traefik v3 (HTTP/1.1 + HTTP/2 + HTTP/3 via QUIC) |
| TLS | Let's Encrypt wildcard `*.tux.bd` via Cloudflare DNS-01 |
| Object storage | Garage v2 (self-hosted S3-compatible) |
| Container mgmt | Docker (ZFS storage driver) + Portainer |
| VPN / remote access | Tailscale |
| Backups | sanoid (ZFS snapshots) → syncoid (local mirror) → rclone (remote) |
| Watchdog | iTCO_wdt hardware watchdog via systemd |
| Swap | ZRAM (zstd, 50% RAM) + NVMe swap (low priority) |

---

## ZFS Pool Layout

```
rpool/
├── local/           # Ephemeral — lost on rollback, not snapshotted
│   ├── root         # /
│   ├── nix          # /nix (Nix store)
│   └── docker       # /var/lib/docker
└── safe/            # AES-256-GCM encrypted — snapshotted + backed up
    ├── home         # /home
    ├── persist      # /persist (all stateful service data)
    ├── garage-meta  # /var/lib/garage/meta (lz4 compressed)
    └── garage-data  # /var/lib/garage/data (compression off, 1M recordsize)
```

Encryption key lives in initrd at `/etc/zfs/safe.key` (embedded at build time via `boot.initrd.secrets`).

---

## Services & Ports

| Service | Port | Access |
|---|---|---|
| SSH | 22 | LAN + Tailscale only |
| HTTP (redirect) | 80 | LAN + Tailscale |
| HTTPS | 443 (TCP+UDP) | LAN + Tailscale |
| SOCKS5 proxy (sing-box) | 1080 | LAN + Tailscale |
| Garage S3 API | 3900 | LAN + Tailscale |
| Garage RPC | 3901 | LAN + Tailscale |
| Traefik dashboard | `https://proxy.tux.bd` | Tailscale only |
| Portainer | `https://admin.tux.bd` | Tailscale only |
| Garage Admin API | 3903 | localhost only |

All ports are blocked from the public internet (`wlo1`) — only LAN (`192.168.31.0/24`) and Tailscale are trusted.

---

## Backup Pipeline

```
rpool/safe/home    ──┐
                     ├── syncoid (daily, ZFS-native) ──► rpool/backup/*
rpool/safe/persist ──┘                                         │
                                                      rclone sync (daily)
                                                               │
                                                    backup-crypt:homeserver-backup
```

Snapshots retained: **24 hourly / 14 daily / 3 monthly** (managed by sanoid).

---

## First-Time Setup

### 1. Clone onto the target machine

```bash
git clone https://github.com/audacioustux/tux.bd ~/tux.bd
```

### 2. Create gitignored local files

```bash
# Hardware identifiers (disk UUIDs, swap device)
cp nixos/hardware.local.nix.example nixos/hardware.local.nix
# Edit with your actual UUIDs — find them with: lsblk -o NAME,UUID,PARTUUID
nvim nixos/hardware.local.nix

# User password hash
cp nixos/machine.local.nix.example nixos/machine.local.nix
# Generate hash: mkpasswd -m yescrypt
nvim nixos/machine.local.nix
```

### 3. Apply the NixOS configuration

```bash
sudo nixos-rebuild switch --flake .#audacioustux-lap-hp1
# or without flakes:
sudo cp -r nixos/* /etc/nixos/
sudo nixos-rebuild switch
```

### 4. Follow POST-BOOT.md

After the first reboot, complete the checklist in [`nixos/POST-BOOT.md`](nixos/POST-BOOT.md):
- Configure rclone for off-disk backup
- Authenticate Tailscale (`sudo tailscale up --ssh`)
- Bootstrap Garage object storage secrets and layout
- Verify ZFS health, snapshot timers, and watchdog

---

## Adding a New Docker Service

Any compose file on the machine can expose a service through Traefik by adding these labels:

```yaml
labels:
  traefik.enable: "true"
  traefik.http.routers.<name>.rule: "Host(`<name>.tux.bd`)"
  traefik.http.routers.<name>.entrypoints: "websecure"
  traefik.http.routers.<name>.tls.certresolver: "letsencrypt"
  traefik.http.services.<name>.loadbalancer.server.port: "<port>"
```

The service must be on the `proxy` Docker network (created by the infra compose stack).

---

## Secrets Layout (never committed)

| File | Purpose | Template |
|---|---|---|
| `nixos/machine.local.nix` | User password hash | `machine.local.nix.example` |
| `nixos/hardware.local.nix` | Disk UUIDs, swap device | `hardware.local.nix.example` |
| `/persist/traefik/secrets.env` | `CF_DNS_API_TOKEN` | `secrets.examples/traefik.secrets.env.example` |
| `/persist/garage/secrets.env` | `GARAGE_RPC_SECRET`, `GARAGE_ADMIN_TOKEN` | `secrets.examples/garage.secrets.env.example` |
| `/persist/backup/rclone.conf` | rclone remote config | — (created by `rclone config`) |

---

## Auto-Sync

Any file change inside `~/tux.bd` triggers an immediate `git commit` via a systemd path unit. A daily timer pushes to GitHub. No manual commits needed for config drift tracking.

---

## License

Personal infrastructure config — use freely for reference.
