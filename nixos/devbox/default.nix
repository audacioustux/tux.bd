# Devboxes: NixOS containers for development work, one per entry in
# `tux.devboxes`. What they are, how to add one, and how to roll back: ./README.md.
#
# Each devbox gets the same layout on the host:
#
#   rpool/safe/devbox/<name>/home        -> /srv/devbox/<name>/home         snapshotted
#   rpool/safe/devbox/<name>/workspaces  -> /srv/devbox/<name>/workspaces   snapshotted
#   rpool/local/devbox/<name>/<slug>     -> /srv/devbox/<name>/local/<slug> not snapshotted
#
# and inside the container those appear as /home/<user>, /workspaces, and
# /home/<user>/<path> for each entry of `unsnapshottedPaths`.
{ config, lib, pkgs, ... }:

let
  inherit (lib) mkOption types;

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
      ${lib.optionalString (box.unsnapshottedPaths != [ ])
        (ensure "rpool/local/devbox/${name}" [ "mountpoint=none" ])}
      ${lib.concatMapStrings (p: ''
        ${ensure "rpool/local/devbox/${name}/${slug p}" [ "mountpoint=${root name}/local/${slug p}" ]}
      '') box.unsnapshottedPaths}
      chown ${toString box.uid}:users ${lib.concatStringsSep " " ([ "${root name}/home" "${root name}/workspaces" ] ++ localDirs)}
    '';

  devboxOptions = { name, ... }: {
    options = {
      sshPort = mkOption {
        type = types.port;
        description = ''
          Port this devbox's sshd listens on. Devboxes share the host's network,
          so every devbox needs a port of its own. It is not opened in the host
          firewall: reach it through the host (ssh, then machinectl) or through
          the host's Cloudflare connector, which connects on localhost.
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
          bind-mounted datasets need no chown in either direction.
        '';
      };

      authorizedKeys = mkOption {
        type = types.listOf types.str;
        default = [ ];
        description = "Public keys allowed to log in as the developer account.";
      };

      extraCapabilities = mkOption {
        type = types.listOf types.str;
        default = [ ];
        example = [ "CAP_PERFMON" ];
        description = ''
          Kernel capabilities beyond systemd-nspawn's default set. Give each
          entry a comment naming the tool that needs it, so it can be removed
          when that tool goes.
        '';
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
in
{
  options.tux.devboxes = mkOption {
    type = types.attrsOf (types.submodule devboxOptions);
    default = { };
    description = "Development containers, by name. See ./README.md.";
  };

  config = lib.mkIf (devboxes != { }) {
    systemd.services = lib.mkMerge [
      {
        devbox-datasets = {
          description = "Ensure ZFS datasets for the devboxes exist";
          wantedBy = [ "multi-user.target" ];
          after = [ "zfs.target" ];
          before = map (name: "container@${name}.service") (lib.attrNames devboxes);
          serviceConfig = { Type = "oneshot"; RemainAfterExit = true; };
          script = ''
            set -eu
            ${ensure "rpool/safe/devbox" [ "mountpoint=none" ]}
            ${ensure "rpool/local/devbox" [ "mountpoint=none" ]}
            ${lib.concatStrings (lib.mapAttrsToList datasetsFor devboxes)}
          '';
        };
      }

      # A container never starts before its datasets are mounted.
      (lib.mapAttrs' (name: _: lib.nameValuePair "container@${name}" {
        requires = [ "devbox-datasets.service" ];
        after = [ "devbox-datasets.service" ];
      }) devboxes)
    ];

    containers = lib.mapAttrs (name: box: {
      autoStart = true;
      privateNetwork = false;
      additionalCapabilities = box.extraCapabilities;
      bindMounts = {
        "/home/${box.user}" = { hostPath = "${root name}/home"; isReadOnly = false; };
        "/workspaces" = { hostPath = "${root name}/workspaces"; isReadOnly = false; };
      } // lib.listToAttrs (map (p: lib.nameValuePair "/home/${box.user}/${p}" {
        hostPath = "${root name}/local/${slug p}";
        isReadOnly = false;
      }) box.unsnapshottedPaths);
      config = {
        imports = [ ./container.nix ];
        tux.devbox = { inherit (box) user uid sshPort authorizedKeys; };
      };
    }) devboxes;

    services.sanoid.datasets = lib.listToAttrs (lib.concatMap (name: [
      (lib.nameValuePair "rpool/safe/devbox/${name}/home" snapshotPolicy)
      (lib.nameValuePair "rpool/safe/devbox/${name}/workspaces" snapshotPolicy)
    ]) (lib.attrNames devboxes));
  };
}
