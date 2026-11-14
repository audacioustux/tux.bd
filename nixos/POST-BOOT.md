# Post-boot checklist

## 1. Configure off-disk backup (required to activate remote push)

The `zfs-backup.service` runs daily but silently skips the remote push
until `/persist/backup/rclone.conf` exists.

```bash
# Create the backup credential directory (encrypted at rest by ZFS)
sudo mkdir -p /persist/backup
sudo chmod 700 /persist/backup

# Configure an rclone remote named exactly "backup-crypt"
# Recommended: create a "crypt" remote wrapping your S3-compatible bucket
# (Backblaze B2, Cloudflare R2, AWS S3, etc.)
sudo rclone config --config /persist/backup/rclone.conf

# Test a manual run
sudo systemctl start zfs-backup.service
sudo journalctl -u zfs-backup.service -f
```

The pipeline:
  rpool/safe/home    ─┐
                      ├─ syncoid (daily, ZFS-native) ─► rpool/backup/*
  rpool/safe/persist ─┘                                      │
                                                    rclone sync (daily, after syncoid)
                                                             │
                                                    backup-crypt:homeserver-backup

## 2. Cloudflare Tunnel (remote access)

Remote access no longer uses Tailscale. A `cloudflared` connector dials out
to Cloudflare; Cloudflare then proxies `devbox.tux.bd` (SSH) and
`k8swalski.tux.bd` (HTTP) to localhost. No inbound WAN ports are opened.

### 2a. Create the tunnel

1. Cloudflare dashboard → **Zero Trust → Networks → Tunnels → Create a tunnel**.
2. Choose **Cloudflared**, name it e.g. `tux-devbox`, save.
3. Copy the connector token from the install command
   (`cloudflared tunnel run --token <TOKEN>`).

Install the token on the host (the service is already enabled but gated on
this file):

```bash
sudo install -m 600 /dev/stdin /persist/cloudflared/token
# paste the token, press Enter, then Ctrl-D
sudo systemctl start cloudflared
sudo systemctl status cloudflared
```

### 2b. Add public hostnames (dashboard → your tunnel → Public Hostname)

| Subdomain     | Domain  | Service           |
|---------------|---------|-------------------|
| `devbox`      | `tux.bd`| `ssh://localhost:22` |
| `k8swalski`   | `tux.bd`| `http://localhost:8080` |

The dashboard creates the proxied CNAME records automatically.

> Delete the old `proxy.tux.bd` and `admin.tux.bd` DNS records — they point
> at the retired Tailscale IP `100.81.170.88`.

### 2c. Protect it with Cloudflare Access

Zero Trust → **Access → Applications**. Create one application per hostname
(or a wildcard `*.tux.bd` policy) with an allow rule for your email/IdP.
Without Access, anyone who learns the hostname can reach the login prompt.

### 2d. Connect over SSH

Add this to the client's `~/.ssh/config` (the client needs `cloudflared`):

```
Host devbox.tux.bd
  ProxyCommand cloudflared access ssh --hostname %h
```

Then `ssh devbox.tux.bd`. Key-only auth is already enforced on the host.

## 3. GitHub Actions runner (nobinalo org)

The runner is enabled but gated on `/persist/github-runner/token`.

1. Create a **fine-grained PAT** with *Organization → Self-hosted runners:
   Read and write* for `nobinalo` (or a classic PAT with `admin:org`).
2. Install it (no trailing newline):

```bash
printf '%s' 'github_pat_...' \
  | sudo install -m 600 -o github-runner -g github-runner /dev/stdin /persist/github-runner/token

sudo systemctl start github-runner-nobinalo
sudo systemctl status github-runner-nobinalo
```

The runner appears at
`https://github.com/organizations/nobinalo/settings/actions/runners` with
labels `self-hosted`, `linux`, `x64`, plus `nixos` if you add it to
`extraLabels` in `nixos/github-runner.nix`.

> `k8swalski`'s workflow currently targets `ubuntu-latest`. To use this
> runner, change `runs-on` to `[self-hosted, linux, x64]` and add the Rust,
> Zig and UPX toolchains to `extraPackages`.

## 4. Docker Swarm + k8swalski

`nixos/swarm.nix` initialises a single-node swarm and deploys
`compose/swarm/k8swalski.yml` on every boot / config change.

```bash
docker stack services k8swalski
docker stack ps k8swalski
curl http://127.0.0.1:8080/livez
sudo systemctl restart k8swalski-stack   # force redeploy
```

k8swalski publishes port 8080 on the node, but 8080 is **not** allowed
through the NixOS firewall — only `cloudflared` (via localhost) can reach it.

## 5. Verify watchdog is active

```bash
sudo systemctl status systemd-watchdog.service 2>/dev/null \
  || cat /sys/class/watchdog/watchdog0/identity
# Should show: iTCO_wdt
```

## 6. Verify ZFS snapshot schedule

```bash
sudo systemctl status sanoid.timer
sudo systemctl status syncoid-safe-home.timer
sudo systemctl status syncoid-safe-persist.timer
```

## 7. Check ZFS pool health

```bash
sudo zpool status
sudo zpool list
```

## 8. Bootstrap Garage object storage

Garage starts but won't serve requests until secrets are placed and the cluster
layout is initialised. Run once after first `nixos-rebuild switch`:

```bash
# Create secrets file on the encrypted /persist volume
sudo mkdir -p /persist/garage
sudo chmod 700 /persist/garage
echo "GARAGE_RPC_SECRET=$(openssl rand -hex 32)"     | sudo tee    /persist/garage/secrets.env
echo "GARAGE_ADMIN_TOKEN=$(openssl rand -base64 32)" | sudo tee -a /persist/garage/secrets.env
sudo chmod 600 /persist/garage/secrets.env

# Restart so Garage picks up the secrets
sudo systemctl restart garage.service
sudo systemctl status  garage.service

# Find the node ID (shown in garage status)
garage status

# Assign this node to a zone and declare its usable capacity, then apply
garage layout assign -z dc1 -c 900G <NODE_ID>
garage layout apply --version 1

# Verify
garage status
garage stats
```

S3 API is on port 3900 (LAN only). Admin API is on 127.0.0.1:3903 (loopback only).
The `garage` CLI wrapper in PATH automatically sources the secrets file.

## 9. Notes

- Boot generations are capped at 5 (EFI partition is 511 MiB).
- Nix GC runs weekly, deleting store paths older than 14 days.
- Weekly ZFS scrub is scheduled; first run happens ~7 days after boot.
- Docker storage driver is ZFS; recordsize on rpool/local/docker is 16K.
- rpool/safe/{home,persist,garage-meta,garage-data} are AES-256-GCM encrypted;
  key is in initrd at /etc/zfs/safe.key (embedded via boot.initrd.secrets).
