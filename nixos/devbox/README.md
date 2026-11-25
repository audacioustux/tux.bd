# Devboxes

A devbox is a NixOS virtual machine on this host for development work. The host
stays clean: projects, their tools and their state live in the devbox, and the
host only provides the hypervisor, storage and network.

It is a VM, not a container, because development needs a kernel of its own:
relay's job sandbox mounts a fresh `/proc`, projects run Docker for multi-node
simulations, and io_uring, eBPF and perf work as they do on bare metal. The VM
runs the host's kernel build, so the kernel features match.

- `default.nix`: the host side. Declares one VM per entry in `tux.devboxes`
  (through [microvm.nix](https://github.com/microvm-nix/microvm.nix), pinned
  there), creates its datasets, and adds them to sanoid.
- `guest.nix`: the inside of every devbox. The developer account, key-only sshd,
  Nix with flakes, optional Docker, nix-ld for downloaded toolchains, and a few
  base tools. Nothing project-specific.

Devboxes are declared in `../features.local.nix` (machine-local, gitignored). See
`../features.local.nix.example` for the shape.

## Storage

| Host dataset | Host mount | Inside the devbox | Snapshots |
|---|---|---|---|
| `rpool/safe/devbox/<name>/home` | `/srv/devbox/<name>/home` | `/home/<user>` | yes (sanoid) |
| `rpool/safe/devbox/<name>/workspaces` | `/srv/devbox/<name>/workspaces` | `/workspaces` | yes (sanoid) |
| `rpool/local/devbox/<name>/<slug>` | `/srv/devbox/<name>/local/<slug>` | `/home/<user>/<path>`, one per `unsnapshottedPaths` entry | no |
| `rpool/local/devbox/<name>/vm` | `/srv/devbox/<name>/vm` | `/var` (`var.img`) and the Nix store layer | no |

The home, workspaces and unsnapshotted paths are host folders shared over
virtiofs: the host sees the same files, owned by the same uid.

Everything else inside the VM is rebuilt on every start from `guest.nix`. In
particular:

- **`/var` persists**, as the disk image `vm/var.img`: Docker's images and
  volumes, the sshd host key, logs.
- **The Nix store layer does not.** The VM reads the host's `/nix/store`, and
  what it builds itself goes to `vm/nix-store-overlay.img`, which is deleted on
  every start, because the VM's Nix database forgets those paths across a
  restart. So load a project's tools with direnv (`use flake`), not `nix
  profile install`: nix-direnv notices its cached shell is gone and rebuilds
  it, from the binary cache, on the first `cd` after a restart. A profile
  would be left pointing at deleted paths.

Restarting or rebuilding a devbox never touches the datasets. The datasets
service only creates what is missing.

The devbox datasets are not yet part of the syncoid and rclone backups.

## Access

sshd is forwarded to `127.0.0.1:<sshPort>` on the host and nowhere else.

- From the host: `ssh -p <sshPort> <user>@localhost`.
- Remotely: through a published route on the host's Cloudflare tunnel, which
  connects to `ssh://localhost:<sshPort>`.

The developer has passwordless sudo inside the devbox.

## Resources

`memory` (MiB) and `vcpu` are fixed while the VM runs. The VM's memory is taken
from the host, so the host caps its ZFS cache (`zfs_arc_max` in
`../configuration.nix`) to leave room for it. Raise one, lower the other.

## Common changes

Each change is an edit to `../features.local.nix`, then `sudo nixos-rebuild
switch`. A switch restarts a devbox whose configuration changed, so stop work
inside it first. Its data stays.

- **Add a devbox.** Add an entry with its own `sshPort`.
- **Change memory or CPUs.** Set `memory` or `vcpu`.
- **Turn on Docker.** Set `docker = true`.
- **Keep a path out of snapshots.** Add it to `unsnapshottedPaths`. Move any
  existing data from that path in the home dataset into the new dataset first.
- **Grow /var.** Stop the VM, then `truncate -s <size>M vm/var.img` and
  `resize2fs vm/var.img`, and set `varSize` to match.
- **Remove a devbox.** Remove its entry and switch. Its datasets stay until you
  `zfs destroy -r rpool/safe/devbox/<name>` (and `rpool/local/devbox/<name>`).

## Rolling back

Configuration: `sudo nixos-rebuild switch --rollback`, or pick the previous
generation at boot. Data: a sanoid snapshot of the home or workspaces dataset,
for example `zfs rollback rpool/safe/devbox/<name>/home@<snapshot>`.
