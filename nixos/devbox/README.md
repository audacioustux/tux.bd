# Devboxes

A devbox is a NixOS container on this host for development work. The host stays
clean: projects, their tools and their state live in the devbox, and the host only
provides the kernel, storage and network.

- `default.nix`: the host side. Declares one container per entry in
  `tux.devboxes`, creates its datasets, and adds them to sanoid.
- `container.nix`: the inside of every devbox. The developer account, key-only
  sshd, Nix with flakes, and a few base tools. Nothing project-specific.

Devboxes are declared in `../features.local.nix` (machine-local, gitignored). See
`../features.local.nix.example` for the shape.

## Storage

| Host dataset | Host mount | Inside the devbox | Snapshots |
|---|---|---|---|
| `rpool/safe/devbox/<name>/home` | `/srv/devbox/<name>/home` | `/home/<user>` | yes (sanoid) |
| `rpool/safe/devbox/<name>/workspaces` | `/srv/devbox/<name>/workspaces` | `/workspaces` | yes (sanoid) |
| `rpool/local/devbox/<name>/<slug>` | `/srv/devbox/<name>/local/<slug>` | `/home/<user>/<path>`, one per `unsnapshottedPaths` entry | no |

Restarting or rebuilding a devbox never touches these datasets. The datasets
service only creates what is missing.

Use `unsnapshottedPaths` for large data that churns, such as clones and caches.
Snapshots of such data pin deleted space for as long as they are kept.

The devbox datasets are not yet part of the syncoid and rclone backups.

## Access

The sshd port is not open on the LAN. Get in one of two ways:

- From the host: `sudo machinectl shell <user>@<name>`, or as root
  `sudo nixos-container root-login <name>`.
- Remotely: through a published route on the host's Cloudflare tunnel, which
  connects to `ssh://localhost:<sshPort>`.

## Common changes

Each change is an edit to `../features.local.nix`, then `sudo nixos-rebuild switch`.
A changed devbox restarts; its data stays.

- **Add a devbox.** Add an entry with its own `sshPort`.
- **Add a capability.** Add it to `extraCapabilities` with a comment naming the
  tool that needs it.
- **Keep a path out of snapshots.** Add it to `unsnapshottedPaths`. Move any
  existing data from that path in the home dataset into the new dataset first.
- **Remove a devbox.** Remove its entry and switch. Its datasets stay until you
  `zfs destroy -r rpool/safe/devbox/<name>` (and `rpool/local/devbox/<name>`).

## Rolling back

Configuration: `sudo nixos-rebuild switch --rollback`, or pick the previous
generation at boot. Data: a sanoid snapshot of the home or workspaces dataset,
for example `zfs rollback rpool/safe/devbox/<name>/home@<snapshot>`.
