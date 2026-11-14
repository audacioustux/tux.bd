{ config, lib, pkgs, ... }:

let
  cfg = config.tux.githubRunner;
  svc = "github-runner-nobinalo";
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
      default = "tux-devbox";
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

      user = "github-runner";
      group = "github-runner";

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
