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
      ];

      # The defaults assume a sandboxed, rootless service. A runner that
      # talks to the host Docker daemon needs both the socket group and
      # an unrestricted user namespace.
      serviceOverrides = {
        PrivateUsers = lib.mkForce false;
        PrivateDevices = lib.mkForce false;
        SupplementaryGroups = [ "docker" ];
      };
    };

    # Don't start (or spam the journal) until the token is provisioned.
    systemd.services.${svc}.unitConfig.ConditionPathExists = cfg.tokenFile;
  };
}
