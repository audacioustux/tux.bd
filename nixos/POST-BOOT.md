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
to Cloudflare; Cloudflare then proxies `box.tux.bd` (SSH) and
`k8swalski.tux.bd` (HTTP) to localhost. No inbound WAN ports are opened.

Tunnel: **TUXBOX** `b74e6a03-6f87-4be8-bce7-65b3127bab3e`
(account `a199fa7663f456591646e01be612f2b6`, zone `tux.bd`).

One hostname per service — the edge maps a hostname to exactly one service,
so a hostname carrying both would need path rules (which leak the prefix
into the origin). Keep it one-to-one:

| Hostname            | Service                    | DNS                               |
|---------------------|----------------------------|-----------------------------------|
| `box.tux.bd`        | `ssh://localhost:22`       | CNAME → `b74e6a03-….cfargotunnel.com` (proxied) |
| `k8swalski.tux.bd`  | `http://localhost:8080`    | same (proxied)                    |
| any                 | `http_status:404` (catch-all) |                              |

```
ssh box.tux.bd                      # SSH (host key auth only)
curl https://k8swalski.tux.bd/livez # k8swalski over TLS at the edge
```

The client always talks HTTPS/443 to the edge; the origin port only ever
appears inside the service URL. The origin sees the path unmodified
(`/livez`, `/readyz`, …).

### 2a. Connector token (already done)

The connector token lives at `/persist/cloudflared/token` (root-only). The
service is gated on it with `ConditionPathExists`, so it simply stays
inactive until the token is there.

```bash
printf '%s' '<TUNNEL_TOKEN>' | sudo install -m 600 /dev/stdin /persist/cloudflared/token
sudo systemctl start cloudflared
sudo systemctl status cloudflared
curl -s http://127.0.0.1:20241/ready   # {"status":200,"readyConnections":N}
```

### 2b. Managing the tunnel with the API (reproducible)

A Cloudflare API token with *Tunnel / DNS / Access* permissions is stored
root-only at `/persist/cloudflare/api-token`. The tunnel ingress and DNS are
managed from it, so they can be re-applied without the dashboard:

```bash
T=$(sudo cat /persist/cloudflare/api-token)
A=a199fa7663f456591646e01be612f2b6
Z=09ee29afcdbaa36aeac7d2203d5fd33e
TN=b74e6a03-6f87-4be8-bce7-65b3127bab3e

# ingress rules (the connector picks this up live, no restart needed)
curl -X PUT -H "Authorization: Bearer $T" -H "Content-Type: application/json" \
  -d '{"config":{"ingress":[
        {"hostname":"box.tux.bd","service":"ssh://localhost:22","originRequest":{}},
        {"hostname":"k8swalski.tux.bd","service":"http://localhost:8080","originRequest":{}},
        {"service":"http_status:404"}]}}' \
  "https://api.cloudflare.com/client/v4/accounts/$A/cfd_tunnel/$TN/configurations"

# DNS
for n in box k8swalski; do
  curl -X POST -H "Authorization: Bearer $T" -H "Content-Type: application/json" \
    -d "{\"type\":\"CNAME\",\"name\":\"$n.tux.bd\",\"content\":\"$TN.cfargotunnel.com\",\"proxied\":true}" \
    "https://api.cloudflare.com/client/v4/zones/$Z/dns_records"
done
```

> The old `proxy.tux.bd` and `admin.tux.bd` A records (pointing at the
> retired Tailscale IP `100.81.170.88`) were deleted.

`warp-routing` (letting WARP clients route the LAN through this tunnel) is
**off** — the API refuses to flip it on an existing tunnel; enable it in the
dashboard under the tunnel's *Private network* tab if you want it.

### 2c. Protect it with Cloudflare Access (optional)

The tunnel mirrors `DEVBOX`, which has **no** Access application: `box.tux.bd`
is public and relies on SSH host-key auth alone. To add SSO:

Zero Trust → **Access → Applications** → add `box.tux.bd` (type
*Self-hosted*) with an allow rule for your email/IdP. The same applies to
`k8swalski.tux.bd` if it should not be world-readable.

### 2d. Connect over SSH

Add this to the client's `~/.ssh/config` (the client needs `cloudflared`):

```
Host box.tux.bd
  ProxyCommand cloudflared access ssh --hostname %h
```

Then `ssh box.tux.bd`. Key-only auth is already enforced on the host.

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
