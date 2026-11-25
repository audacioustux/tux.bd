# Devboxes: NixOS virtual machines for development work, one per entry in
# `tux.devboxes`. What they are, how to add one, and how to roll back: ./README.md.
#
# A devbox is a VM, not a container, because it needs its own kernel: relay's
# sandbox mounts a fresh /proc, and projects run nested containers, which
# systemd-nspawn does not allow.
#
# Each devbox gets the same layout on the host:
#
#   rpool/safe/devbox/<name>/home        -> /srv/devbox/<name>/home         snapshotted
#   rpool/safe/devbox/<name>/workspaces  -> /srv/devbox/<name>/workspaces   snapshotted
#   rpool/local/devbox/<name>/<slug>     -> /srv/devbox/<name>/local/<slug> not snapshotted
#   rpool/local/devbox/<name>/vm         -> /srv/devbox/<name>/vm           not snapshotted
#
# and inside the VM those appear as /home/<user>, /workspaces, and
# /home/<user>/<path> for each entry of `unsnapshottedPaths`, shared over
# virtiofs. The vm dataset holds the VM's disk images: /var, which persists
# (Docker's data, the sshd host key), and the writable Nix store layer, which
# is recreated on every start.
{ config, lib, pkgs, ... }:

let
  inherit (lib) mkOption types;

  # microvm.nix, pinned. To update: pick a commit, then
  #   nix-prefetch-url --unpack https://github.com/microvm-nix/microvm.nix/archive/<rev>.tar.gz
  microvm = builtins.fetchTarball {
    url = "https://github.com/microvm-nix/microvm.nix/archive/430a46d03ef15f1b8b715fafa85f21847960b783.tar.gz";
    sha256 = "1bw4ma5ykr5hz8r0hcikw3adgnfnmcgaww147rqm0f9aayxqzfws";
  };

  zfs = "${config.boot.zfs.package}/bin/zfs";
  devboxes = config.tux.devboxes;

  root = name: "/srv/devbox/${name}";

  # ".local/share/relay" -> "local-share-relay": one flat dataset name per path.
  slug = path: lib.replaceStrings [ "/" ] [ "-" ] (lib.removePrefix "." path);

  # Create a dataset only if it is missing. Existing data is never touched.
  ensure = dataset: opts:
    let o = lib.concatMapStringsSep " " (kv: "-o ${kv}") opts;
    in "${zfs} list ${dataset} >/dev/null 2>&1 || ${zfs} create ${o} ${dataset}";

  # Same retention as rpool/safe/home in ../configuration.nix.
  snapshotPolicy = { hourly = 24; daily = 14; monthly = 3; autosnap = true; autoprune = true; };

  # Shell lines that create one devbox's datasets and give them to its user.
  datasetsFor = name: box:
    let localDirs = map (p: "${root name}/local/${slug p}") box.unsnapshottedPaths;
    in ''
      ${ensure "rpool/safe/devbox/${name}" [ "mountpoint=none" ]}
      ${ensure "rpool/safe/devbox/${name}/home" [ "mountpoint=${root name}/home" ]}
      ${ensure "rpool/safe/devbox/${name}/workspaces" [ "mountpoint=${root name}/workspaces" ]}
      ${ensure "rpool/local/devbox/${name}" [ "mountpoint=none" ]}
      ${ensure "rpool/local/devbox/${name}/vm" [ "mountpoint=${root name}/vm" ]}
      ${lib.concatMapStrings (p: ''
        ${ensure "rpool/local/devbox/${name}/${slug p}" [ "mountpoint=${root name}/local/${slug p}" ]}
        # The mount point inside the home, owned by the user, so its parents
        # are writable by the user too.
        d=${root name}/home
        for part in ${lib.concatStringsSep " " (lib.splitString "/" p)}; do
          d="$d/$part"; mkdir -p "$d"; chown ${toString box.uid}:users "$d"
        done
      '') box.unsnapshottedPaths}
      chown ${toString box.uid}:users ${lib.concatStringsSep " " ([ "${root name}/home" "${root name}/workspaces" ] ++ localDirs)}
      # The hypervisor runs as microvm and creates its disk images here.
      chown microvm:kvm ${root name}/vm
    '';

  devboxOptions = { name, ... }: {
    options = {
      sshPort = mkOption {
        type = types.port;
        description = ''
          Host port forwarded to the devbox's sshd, on 127.0.0.1 only. Every
          devbox needs a port of its own. Reach it from the host, or through the
          host's Cloudflare connector, which connects on localhost.
        '';
      };

      vcpu = mkOption {
        type = types.ints.positive;
        default = 4;
        description = "Virtual CPU cores.";
      };

      memory = mkOption {
        type = types.ints.positive;
        default = 4096;
        description = "Memory in MiB. Fixed while the devbox runs; the host keeps the rest.";
      };

      varSize = mkOption {
        type = types.ints.positive;
        default = 131072;
        description = ''
          Size in MiB of the VM's /var image (sparse: it takes only what is
          written). Holds Docker's images and volumes. Growing it later means
          resizing the image; see ./README.md.
        '';
      };

      storeSize = mkOption {
        type = types.ints.positive;
        default = 65536;
        description = ''
          Size in MiB of the VM's writable Nix store layer (sparse). It is
          recreated on every start; see ./README.md.
        '';
      };

      user = mkOption {
        type = types.str;
        default = "vscode";
        description = "The developer account inside the devbox.";
      };

      uid = mkOption {
        type = types.int;
        default = 1000;
        description = ''
          The account's uid. It matches the host owner's uid, so files in the
          shared datasets need no chown in either direction.
        '';
      };

      authorizedKeys = mkOption {
        type = types.listOf types.str;
        default = [ ];
        description = "Public keys allowed to log in as the developer account.";
      };

      docker = mkOption {
        type = types.bool;
        default = false;
        description = "A Docker daemon inside the devbox, with the developer in its group.";
      };

      unsnapshottedPaths = mkOption {
        type = types.listOf types.str;
        default = [ ];
        example = [ ".local/share/relay" ];
        description = ''
          Paths under the account's home kept on a dataset without snapshots.
          For large data that churns, such as clones and caches, where
          snapshots would pin deleted space for months.
        '';
      };
    };
  };

  # The VM side of one devbox: hardware, shares and ports, then ./guest.nix.
  vmFor = name: box: {
    autostart = true;
    config = {
      imports = [ ./guest.nix ];
      tux.devbox = { inherit (box) user uid authorizedKeys docker; };

      # The host's kernel, so the devbox has the same io_uring and eBPF features.
      boot.kernelPackages = config.boot.kernelPackages;

      microvm = {
        hypervisor = "qemu";
        inherit (box) vcpu;
        mem = box.memory;

        # User-mode networking: outbound access with no host network setup.
        # Inbound, only sshd, and only from the host itself.
        interfaces = [ { type = "user"; id = "usernet"; mac = "02:00:00:00:00:01"; } ];
        forwardPorts = [ { from = "host"; host.address = "127.0.0.1"; host.port = box.sshPort; guest.port = 22; } ];

        shares = [
          { proto = "virtiofs"; tag = "ro-store"; source = "/nix/store"; mountPoint = "/nix/.ro-store"; posixAcl = false; }
          { proto = "virtiofs"; tag = "home"; source = "${root name}/home"; mountPoint = "/home/${box.user}"; }
          { proto = "virtiofs"; tag = "workspaces"; source = "${root name}/workspaces"; mountPoint = "/workspaces"; }
        ] ++ map (p: {
          proto = "virtiofs";
          tag = slug p;
          source = "${root name}/local/${slug p}";
          mountPoint = "/home/${box.user}/${p}";
        }) box.unsnapshottedPaths;

        # Builds inside the VM go to a layer over the shared host store.
        writableStoreOverlay = "/nix/.rw-store";
        volumes = [
          { image = "${root name}/vm/var.img"; mountPoint = "/var"; size = box.varSize; }
          { image = "${root name}/vm/nix-store-overlay.img"; mountPoint = "/nix/.rw-store"; size = box.storeSize; }
        ];
      };
    };
  };
in
{
  imports = [ "${microvm}/nixos-modules/host" ];

  options.tux.devboxes = mkOption {
    type = types.attrsOf (types.submodule devboxOptions);
    default = { };
    description = "Development VMs, by name. See ./README.md.";
  };

  config = lib.mkIf (devboxes != { }) {
    microvm.vms = lib.mapAttrs vmFor devboxes;

    systemd.services = lib.mkMerge [
      {
        devbox-datasets = {
          description = "Ensure ZFS datasets for the devboxes exist";
          wantedBy = [ "multi-user.target" ];
          after = [ "zfs.target" ];
          before = map (name: "microvm@${name}.service") (lib.attrNames devboxes);
          serviceConfig = { Type = "oneshot"; RemainAfterExit = true; };
          script = ''
            set -eu
            ${ensure "rpool/safe/devbox" [ "mountpoint=none" ]}
            ${ensure "rpool/local/devbox" [ "mountpoint=none" ]}
            ${lib.concatStrings (lib.mapAttrsToList datasetsFor devboxes)}
          '';
        };
      }

      # A devbox never starts before its datasets are mounted. Its writable
      # store layer starts empty each time: the Nix database inside the VM
      # forgets what it built across a restart, so a kept layer would be stale.
      (lib.mapAttrs' (name: _: lib.nameValuePair "microvm@${name}" {
        requires = [ "devbox-datasets.service" ];
        after = [ "devbox-datasets.service" ];
        preStart = lib.mkBefore "rm -f ${root name}/vm/nix-store-overlay.img";
      }) devboxes)
    ];

    services.sanoid.datasets = lib.listToAttrs (lib.concatMap (name: [
      (lib.nameValuePair "rpool/safe/devbox/${name}/home" snapshotPolicy)
      (lib.nameValuePair "rpool/safe/devbox/${name}/workspaces" snapshotPolicy)
    ]) (lib.attrNames devboxes));
  };
}
