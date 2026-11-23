{ config, lib, pkgs, ... }:

let
  cfg = config.tux.githubRunner;
  svc = "github-runner-nobinalo";

  # The github-runner in the 25.11 channel is 2.331.0, which GitHub has
  # deprecated ("Runner version v2.331.0 is deprecated and cannot receive
  # messages") — it registers fine and then refuses jobs. Pin a current
  # release (2.338.2) from one specific nixpkgs revision rather than
  # upgrading the whole system just to move one package.
  runnerPkgs = import (builtins.fetchTarball {
    url = "https://github.com/NixOS/nixpkgs/archive/2074cc672349f14240fb7ea90d509e0b643e9dd4.tar.gz";
    sha256 = "sha256-E0hYoioqUtM2XmPPvYYpJgdADF5AW9oOoPSEiM9dTHQ=";
  }) { system = pkgs.stdenv.hostPlatform.system; };

  runnerPackage = runnerPkgs.github-runner;

  zfs = "${config.boot.zfs.package}/bin/zfs";

  # Disk for jobs. The module's default HOME and work directory are the
  # service's RuntimeDirectory, a 2.9 GB tmpfs held in RAM. A ZFS dataset with
  # a quota instead: the checkout, ~/.rustup and the persistent cargo target
  # directories (TheGrid keeps them under ~/.cache/thegrid-ci, bounded by its
  # own cap) live here and can never fill the pool.
  cacheDataset = "rpool/local/github-runner";
  cacheDir = "/var/cache/github-runner";
in
{
  options.tux.githubRunner = {
    enable = lib.mkEnableOption "GitHub Actions self-hosted runner for the nobinalo organisation";

    url = lib.mkOption {
      type = lib.types.str;
      default = "https://github.com/nobinalo";
      description = "Organisation or repository URL to register the runner against.";
    };

    name = lib.mkOption {
      type = lib.types.str;
      default = "tux-box";
      description = "Runner name shown in GitHub.";
    };

    tokenFile = lib.mkOption {
      type = lib.types.path;
      default = "/persist/github-runner/token";
      description = ''
        File containing a fine-grained PAT with read/write access to
        organisation self-hosted runners (or a 1-hour registration token).
        Must be readable by the `github-runner` user.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    users.groups.github-runner = { };

    users.users.github-runner = {
      isSystemUser = true;
      group = "github-runner";
      extraGroups = [ "docker" ];
      home = "/var/lib/github-runner";
      createHome = true;
      description = "GitHub Actions self-hosted runner";
    };

    systemd.tmpfiles.rules = [
      "d /persist/github-runner 0750 root github-runner -"
    ];

    services.github-runners.nobinalo = {
      enable = true;
      url = cfg.url;
      name = cfg.name;
      tokenFile = cfg.tokenFile;
      replace = true;
      package = runnerPackage;

      user = "github-runner";
      group = "github-runner";

      # Runner group, so the runner is only offered to the repositories and
      # workflows in that group (nobinalo/k8swalski and nobinalo/TheGrid, and
      # their build workflows). Without it the runner lands in the org's
      # Default group, which every repository of the org can use.
      runnerGroup = "tux-box";
      extraLabels = [ "tux-box" ];

      # Node 20 is EOL and no longer shipped by current nixpkgs, so the
      # pinned runner only supports node24.
      nodeRuntimes = [ "node24" ];

      extraPackages = with pkgs; [
        bashInteractive
        coreutils
        git
        curl
        jq
        gnutar
        gzip
        unzip
        docker-client

        # TheGrid's kernel job: rustup installs the pinned nightly from
        # rust-toolchain.toml (nixpkgs' rustup patches what it downloads for
        # NixOS), cc links, valgrind runs the instruction ledgers.
        rustup
        gcc
        valgrind
        pkg-config
        gnumake
        perl
        gawk
        # `ldd --version`: taiki-e/install-action reads the glibc version
        # from it and exits silently without it.
        glibc.bin
      ];

      # The module empties this on every service start; HOME (below) it keeps.
      workDir = "${cacheDir}/work";

      # The defaults assume a sandboxed, rootless service. A runner that
      # talks to the host Docker daemon needs both the socket group and
      # an unrestricted user namespace.
      serviceOverrides = {
        PrivateUsers = lib.mkForce false;
        PrivateDevices = lib.mkForce false;
        SupplementaryGroups = [ "docker" ];

        # Resource limits. A job here is root-equivalent through the Docker
        # socket, and the box also runs the tunnel (the only remote access
        # to it), garage and the swarm stack — so a job must not be able to
        # take the box down. All but one core, and memory well inside the
        # box's 11 GiB (6 GiB of which is reclaimable ZFS ARC). IOWeight
        # keeps it from starving ZFS commits and the backup timers.
        CPUQuota = "700%";       # 7 of 8 cores
        MemoryMax = "6G";
        MemorySwapMax = "2G";
        IOWeight = "50";

        ReadWritePaths = [ cacheDir ];

        # io_uring's registered buffers are charged to RLIMIT_MEMLOCK (8 MiB by
        # default); TheGrid runs a reactor per shard, each pinning its pool.
        # MemoryMax above already bounds the job's memory.
        LimitMEMLOCK = "infinity";

        # TheGrid's root-custody tests set the setuid bit on a file the job owns
        # (mode 4600) to prove the host refuses it; the module's default refuses
        # that chmod. A job here is already root-equivalent through the Docker
        # socket, so the restriction guards nothing.
        RestrictSUIDSGID = lib.mkForce false;
      };
    };

    # Don't start (or spam the journal) until the token is provisioned.
    systemd.services.${svc} = {
      unitConfig.ConditionPathExists = cfg.tokenFile;
      environment.HOME = lib.mkForce cacheDir;
      requires = [ "github-runner-disk.service" ];
      after = [ "github-runner-disk.service" ];
    };

    # The runner's disk, and the quota on Docker's dataset: a job reaches
    # dockerd through the socket, outside the runner's own cgroup limits.
    systemd.services.github-runner-disk = {
      description = "ZFS datasets and quotas for the GitHub runner";
      after = [ "zfs.target" ];
      path = [ pkgs.coreutils ];
      serviceConfig = { Type = "oneshot"; RemainAfterExit = true; };
      script = ''
        ${zfs} list ${cacheDataset} >/dev/null 2>&1 \
          || ${zfs} create -o mountpoint=${cacheDir} ${cacheDataset}
        ${zfs} set quota=120G ${cacheDataset}
        ${zfs} set quota=60G rpool/local/docker
        install -d -o github-runner -g github-runner -m 0750 ${cacheDir} ${cacheDir}/work
      '';
    };

    # Prebuilt Linux tools a job downloads (cargo-nextest through
    # taiki-e/install-action) expect /lib64/ld-linux; NixOS has none.
    programs.nix-ld.enable = true;
  };
}
