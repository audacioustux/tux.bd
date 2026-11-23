{ config, pkgs, lib, ... }:

let
  zfs = "${config.boot.zfs.package}/bin/zfs";

  zfsEnsure = dataset: attrs:
    let opts = lib.concatStringsSep " " (map (kv: "-o ${kv}") attrs);
    in "${zfs} list ${dataset} 2>/dev/null || ${zfs} create ${opts} ${dataset}";

  repoDir = "/home/audacioustux/tux.bd";

  # Kernel 7.2 (owner, 2026-11-15: the newest kernel a ZFS release supports; TheGrid's
  # io_uring floor is 7.0, D133). The root pool is on ZFS, and OpenZFS 2.4.4 supports Linux up
  # to 7.2; no release supports 7.3 yet. nixos-unstable dropped 7.2 (end of life) on
  # 2026-11-07, so the kernel comes from the last nixos-unstable before that (prebuilt in the
  # binary cache). ZFS 2.4.4 is built here from this system's own nixpkgs (./zfs-2_4_4.nix),
  # module against that kernel, so the initrd's ZFS tools link against the system's glibc
  # (unstable's do not, and the initrd refuses them). Move to linuxPackages_latest once an
  # OpenZFS release supports it, and never `zpool upgrade` while a 2.3 generation is still
  # a boot fallback.
  kernelSource = import (builtins.fetchTarball {
    url = "https://github.com/NixOS/nixpkgs/archive/dae4eae944b1c16f5a002916bc8c95a639067ff8.tar.gz";
    sha256 = "088l3by79b3q7a3gz3fx1zlpdyjv506727wjjw2gxpa0gshbvgzr";
  }) { system = pkgs.stdenv.hostPlatform.system; };
  zfs244 = pkgs.callPackage ./zfs-2_4_4.nix { configFile = "user"; };
  kernelPackages = (pkgs.linuxPackagesFor kernelSource.linux_7_2).extend (self: _: {
    # The module builds with the kernel's own stdenv (unstable's), as it must; 25.11's
    # platform patterns do not match unstable's platform record, so name the system instead.
    zfs_2_4 = (self.callPackage ./zfs-2_4_4.nix { configFile = "kernel"; inherit pkgs; inherit (self) kernel; })
      .overrideAttrs (old: { meta = old.meta // { platforms = [ "x86_64-linux" ]; }; });
  });
in {
  imports = [
    ./hardware-configuration.nix
    ./machine.local.nix       # gitignored — see machine.local.nix.example
    ./cloudflared.nix
    ./swarm.nix
    ./github-runner.nix
  ] ++ lib.optional (builtins.pathExists ./features.local.nix) ./features.local.nix;

  # ── Boot ────────────────────────────────────────────────────────────────────
  boot.loader.systemd-boot.enable             = true;
  boot.loader.systemd-boot.configurationLimit = 5;
  boot.loader.efi.canTouchEfiVariables        = true;
  boot.kernelPackages                         = kernelPackages;
  boot.zfs.package                            = zfs244;

  # ── Watchdog ────────────────────────────────────────────────────────────────
  # iTCO_wdt: systemd pets every 15 s; firmware hard-resets after 30 s stall.
  systemd.settings.Manager = {
    RuntimeWatchdogSec = "30s";
    RebootWatchdogSec  = "10m";
    KExecWatchdogSec   = "10m";
  };

  # ── ZFS ─────────────────────────────────────────────────────────────────────
  boot.supportedFilesystems        = [ "zfs" ];
  boot.zfs.forceImportRoot         = false;
  boot.initrd.secrets              = { "/etc/zfs/safe.key" = "/etc/zfs/safe.key"; };
  # ARC 6 GiB. panic=10: a kernel panic reboots in 10 s instead of hanging, so a one-shot
  # boot of a new kernel that fails falls back to the default entry by itself; boot.panic_on_fail
  # turns a stage 1 failure (a pool that will not import) into that panic instead of a prompt.
  boot.kernelParams                = [ "zfs.zfs_arc_max=6442450944" "panic=10" "boot.panic_on_fail" ];
  boot.extraModprobeConfig         = "options zfs zfs_txg_timeout=30";  # batch writes
  networking.hostId                = "8424e348";
  services.zfs.autoScrub           = { enable = true; interval = "weekly"; };
  services.zfs.trim.enable         = true;

  # ── Snapshots (sanoid) ──────────────────────────────────────────────────────
  # rpool/safe/* — all persistent data. Retention: 24h / 14d / 3mo.
  services.sanoid = {
    enable   = true;
    datasets =
      let snap = { hourly = 24; daily = 14; monthly = 3; autosnap = true; autoprune = true; };
      in {
        "rpool/safe/home"        = snap;
        "rpool/safe/persist"     = snap;
        "rpool/safe/garage-meta" = snap;
        "rpool/safe/garage-data" = snap;
      };
  };

  # ── Backup: syncoid (local) + rclone (remote) ───────────────────────────────
  # Stage 1 — daily ZFS mirror: rpool/safe/* → rpool/backup/*
  # Stage 2 — daily rclone push to backup-crypt remote
  #           (skipped gracefully if /persist/backup/rclone.conf absent)
  services.syncoid = {
    enable   = true;
    interval = "daily";
    commands = {
      "safe-home"    = { source = "rpool/safe/home";    target = "rpool/backup/home";    extraArgs = [ "--no-privilege-elevation" ]; };
      "safe-persist" = { source = "rpool/safe/persist"; target = "rpool/backup/persist"; extraArgs = [ "--no-privilege-elevation" ]; };
    };
  };

  systemd.services.zfs-backup-init = {
    description   = "Ensure ZFS backup datasets exist";
    wantedBy      = [ "multi-user.target" ];
    after         = [ "zfs.target" ];
    before        = [ "syncoid-safe-home.service" "syncoid-safe-persist.service" ];
    serviceConfig = { Type = "oneshot"; RemainAfterExit = true; };
    script = ''
      ${zfsEnsure "rpool/backup"         [ "mountpoint=none" ]}
      ${zfsEnsure "rpool/backup/home"    [ "mountpoint=/backup/home" ]}
      ${zfsEnsure "rpool/backup/persist" [ "mountpoint=/backup/persist" ]}
    '';
  };

  systemd.services.zfs-backup = {
    description   = "ZFS off-disk backup via rclone";
    after         = [ "network-online.target" "syncoid-safe-home.service" "syncoid-safe-persist.service" ];
    wants         = [ "network-online.target" ];
    serviceConfig = { Type = "oneshot"; User = "root"; TimeoutStartSec = "2h"; };
    script = pkgs.writeShellApplication {
      name  = "zfs-backup";
      runtimeInputs = [ pkgs.rclone ];
      text  = ''
        conf=/persist/backup/rclone.conf
        [[ -f $conf ]] || { echo "rclone.conf not found, skipping"; exit 0; }
        rclone sync --config "$conf" --checksum --transfers 4 /backup backup-crypt:homeserver-backup
      '';
    } + "/bin/zfs-backup";
  };

  systemd.timers.zfs-backup = {
    wantedBy    = [ "timers.target" ];
    timerConfig = { OnCalendar = "daily"; RandomizedDelaySec = "30min"; Persistent = true; };
  };

  # ── Garage S3 ───────────────────────────────────────────────────────────────
  # Single-node, ZFS-backed: garage-meta (lz4) + garage-data (off, 1M records).
  # Secrets: /persist/garage/secrets.env (GARAGE_RPC_SECRET, GARAGE_ADMIN_TOKEN)
  systemd.services.garage-zfs-init = {
    description   = "Ensure ZFS datasets for Garage exist";
    wantedBy      = [ "multi-user.target" ];
    after         = [ "zfs.target" ];
    before        = [ "garage.service" ];
    serviceConfig = { Type = "oneshot"; RemainAfterExit = true; };
    script = ''
      ${zfsEnsure "rpool/safe/garage-meta" [ "mountpoint=/var/lib/garage/meta" "compression=lz4" ]}
      ${zfsEnsure "rpool/safe/garage-data" [ "mountpoint=/var/lib/garage/data" "compression=off" "recordsize=1M" ]}
      chown garage:garage /var/lib/garage/meta /var/lib/garage/data
      chmod 750           /var/lib/garage/meta /var/lib/garage/data
    '';
  };

  services.garage = {
    enable          = true;
    package         = pkgs.garage_2;
    environmentFile = "/persist/garage/secrets.env";
    settings = {
      replication_factor              = 1;
      db_engine                       = "lmdb";
      metadata_dir                    = "/var/lib/garage/meta";
      data_dir                        = "/var/lib/garage/data";
      metadata_fsync                  = true;
      metadata_auto_snapshot_interval = "6h";
      block_size                      = "1M";
      rpc_bind_addr                   = "[::]:3901";
      rpc_public_addr                 = "127.0.0.1:3901";
      s3_api = { api_bind_addr = "[::]:3900"; s3_region = "garage"; root_domain = ".s3.garage.localhost"; };
      admin.api_bind_addr             = "127.0.0.1:3903";
    };
  };

  # Static garage user — DynamicUser breaks ZFS dataset ownership across reboots.
  systemd.services.garage = {
    after    = lib.mkMerge [ (lib.mkDefault [ "network.target" "network-online.target" ]) [ "garage-zfs-init.service" ] ];
    requires = [ "garage-zfs-init.service" ];
    serviceConfig = { DynamicUser = lib.mkForce false; User = "garage"; Group = "garage"; };
  };

  users.users.garage  = { isSystemUser = true; group = "garage"; description = "Garage S3 daemon"; };
  users.groups.garage = {};

  # ── Swap ────────────────────────────────────────────────────────────────────
  # ZRAM first (NixOS auto-sets higher priority); NVMe swap only under pressure.
  # NVMe partuuid is in hardware.local.nix (gitignored).
  zramSwap                           = { enable = true; algorithm = "zstd"; memoryPercent = 50; };
  boot.kernel.sysctl."vm.swappiness" = 10;

  # ── Laptop-as-server ────────────────────────────────────────────────────────
  services.logind.settings.Login = {
    HandleLidSwitch              = "ignore";
    HandleLidSwitchExternalPower = "ignore";
  };
  systemd.sleep.extraConfig = ''
    AllowSuspend=no
    AllowHibernation=no
    AllowHybridSleep=no
    AllowSuspendThenHibernate=no
  '';

  # ── Networking ──────────────────────────────────────────────────────────────
  time.timeZone                    = "Asia/Dhaka";
  networking.hostName              = "audacioustux-lap-hp1";
  networking.networkmanager.enable = true;

  # ── Firewall ────────────────────────────────────────────────────────────────
  # LAN (192.168.31.0/24) only. Remote access goes out through the
  # Cloudflare Tunnel (cloudflared connects outbound and proxies to
  # localhost), so no inbound WAN ports are required.
  networking.firewall = {
    enable            = true;
    allowedTCPPorts   = [ 22 1080 3900 3901 ];
    allowedUDPPorts   = [ 1080 ];
    # Devcontainer ports (manifest: 8000-8007, 4433-4440). LAN only, like the rest.
    allowedTCPPortRanges = [ { from = 8000; to = 8007; } { from = 4433; to = 4440; } ];
    allowedUDPPortRanges = [ { from = 8000; to = 8007; } { from = 4433; to = 4440; } ];
    extraCommands = ''
      iptables -I nixos-fw 1 -p tcp -m multiport --dports 22,1080,3900,3901 ! -s 192.168.31.0/24 -i wlo1 -j nixos-fw-refuse
      iptables -I nixos-fw 1 -p udp -m multiport --dports 1080               ! -s 192.168.31.0/24 -i wlo1 -j nixos-fw-refuse
      iptables -I nixos-fw 1 -p tcp -m multiport --dports 8000:8007,4433:4440 ! -s 192.168.31.0/24 -i wlo1 -j nixos-fw-refuse
      iptables -I nixos-fw 1 -p udp -m multiport --dports 8000:8007,4433:4440 ! -s 192.168.31.0/24 -i wlo1 -j nixos-fw-refuse
    '';
    extraStopCommands = ''
      iptables -D nixos-fw -p tcp -m multiport --dports 22,1080,3900,3901 ! -s 192.168.31.0/24 -i wlo1 -j nixos-fw-refuse 2>/dev/null || true
      iptables -D nixos-fw -p udp -m multiport --dports 1080               ! -s 192.168.31.0/24 -i wlo1 -j nixos-fw-refuse 2>/dev/null || true
      iptables -D nixos-fw -p tcp -m multiport --dports 8000:8007,4433:4440 ! -s 192.168.31.0/24 -i wlo1 -j nixos-fw-refuse 2>/dev/null || true
      iptables -D nixos-fw -p udp -m multiport --dports 8000:8007,4433:4440 ! -s 192.168.31.0/24 -i wlo1 -j nixos-fw-refuse 2>/dev/null || true
    '';
  };

  # ── Services ────────────────────────────────────────────────────────────────
  services.fail2ban   = { enable = true; maxretry = 5; };
  services.avahi      = { enable = true; nssmdns4 = true; publish = { enable = true; addresses = true; }; };

  services.sing-box = {
    enable   = true;
    settings = {
      log.level = "info";
      inbounds  = [{ type = "socks"; tag = "socks-in"; listen = "0.0.0.0"; listen_port = 1080; sniff = true; }];
      outbounds = [{ type = "direct"; tag = "direct"; }];
    };
  };

  services.openssh = {
    enable   = true;
    settings = { PermitRootLogin = "no"; PasswordAuthentication = false; KbdInteractiveAuthentication = false; };
  };

  # ── Docker ──────────────────────────────────────────────────────────────────
  # iptables=false keeps Docker from bypassing the NixOS firewall and still
  # works for this single-node swarm (validated with k8swalski).
  virtualisation.docker = {
    enable                   = true;
    storageDriver            = "zfs";
    daemon.settings.iptables = false;
    autoPrune                = { enable = true; dates = "weekly"; flags = [ "--all" ]; };
  };

  # Containers need outbound NAT. Docker's own iptables stay off (above), so the
  # NixOS NAT module masquerades the docker0 bridge instead.
  networking.nat = { enable = true; internalInterfaces = [ "docker0" ]; externalInterface = "wlo1"; };

  # ── Users ───────────────────────────────────────────────────────────────────
  users.mutableUsers                        = false;
  users.users.root.hashedPassword           = "!";
  security.sudo.wheelNeedsPassword          = false;

  users.users.audacioustux = {
    isNormalUser = true;
    extraGroups  = [ "wheel" "networkmanager" "docker" ];
    # hashedPassword in machine.local.nix (gitignored)
    openssh.authorizedKeys.keys = [
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIEXWBoJfED5lM/FJUoGLxUqAac/NWCQymTCaGeaiWNjv"
    ];
  };

  # ── Nix ─────────────────────────────────────────────────────────────────────
  nix.settings.experimental-features = [ "nix-command" "flakes" ];
  nix.gc = { automatic = true; dates = "weekly"; options = "--delete-older-than 14d"; };

  # ── Packages ────────────────────────────────────────────────────────────────
  environment.systemPackages = with pkgs; [
    git curl wget btop iotop
    sanoid rclone age openssl
    docker-compose neovim cloudflared gh
  ];

  # ── Config repo auto-sync ───────────────────────────────────────────────────
  # File change in ~/tux.bd → immediate commit. Daily timer → push to GitHub.
  systemd.services.config-repo-commit = {
    description   = "Auto-commit changes in ~/tux.bd";
    serviceConfig = {
      Type             = "oneshot";
      User             = "audacioustux";
      WorkingDirectory = repoDir;
      ExecStart        = pkgs.writeShellApplication {
        name          = "config-repo-commit";
        runtimeInputs = [ pkgs.git ];
        text          = ''
          git add -A
          # Unsigned: the signing key for this repo lives on another machine
          # and is not available here, so a signed auto-commit always failed.
          git diff --cached --quiet || git -c commit.gpgsign=false commit -m "auto: sync $(date -u +%Y-%m-%dT%H:%M:%SZ)"
        '';
      } + "/bin/config-repo-commit";
    };
  };

  systemd.paths.config-repo-commit = {
    wantedBy   = [ "multi-user.target" ];
    pathConfig = { PathChanged = repoDir; };
  };

  systemd.services.config-repo-push = {
    description   = "Daily git push for ~/tux.bd";
    after         = [ "network-online.target" ];
    wants         = [ "network-online.target" ];
    serviceConfig = {
      Type             = "oneshot";
      User             = "audacioustux";
      WorkingDirectory = repoDir;
      ExecStart        = pkgs.writeShellApplication {
        name          = "config-repo-push";
        runtimeInputs = [ pkgs.git ];
        text          = "git push";
      } + "/bin/config-repo-push";
    };
  };

  systemd.timers.config-repo-push = {
    wantedBy    = [ "timers.target" ];
    timerConfig = { OnCalendar = "daily"; RandomizedDelaySec = "30min"; Persistent = true; };
  };

  system.stateVersion = "25.11";
}
