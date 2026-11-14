{ config, lib, pkgs, ... }:

let
  cfg = config.tux.cloudflared;
in
{
  options.tux.cloudflared = {
    enable = lib.mkEnableOption "Cloudflare Tunnel connector (token-managed)";

    tokenFile = lib.mkOption {
      type = lib.types.path;
      default = "/persist/cloudflared/token";
      description = ''
        Root-readable file containing the Cloudflare Tunnel token.
        The tunnel and its public hostnames (ingress) are managed in the
        Cloudflare Zero Trust dashboard.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    systemd.tmpfiles.rules = [
      "d /persist/cloudflared 0700 root root -"
    ];

    systemd.services.cloudflared = {
      description = "Cloudflare Tunnel connector";
      wantedBy = [ "multi-user.target" ];
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];

      # Don't crash-loop before the token has been provisioned.
      unitConfig.ConditionPathExists = cfg.tokenFile;

      serviceConfig = {
        Type = "simple";
        DynamicUser = true;
        LoadCredential = "tunnel-token:${cfg.tokenFile}";
        ExecStart = "${lib.getExe pkgs.cloudflared} tunnel --no-autoupdate run --token-file %d/tunnel-token";
        Restart = "on-failure";
        RestartSec = 5;

        # Hardening
        NoNewPrivileges = true;
        PrivateTmp = true;
        PrivateDevices = true;
        ProtectSystem = "strict";
        ProtectHome = true;
        ProtectKernelTunables = true;
        ProtectKernelModules = true;
        ProtectControlGroups = true;
        RestrictAddressFamilies = [ "AF_INET" "AF_INET6" "AF_UNIX" ];
        LockPersonality = true;
      };
    };
  };
}
