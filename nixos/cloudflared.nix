{ config, lib, pkgs, ... }:

let
  cfg = config.tux.cloudflared;

  # A local config, so the connector serves the right routes between process
  # start and the first remote push. The dashboard stays authoritative — a
  # remotely managed tunnel's remote config replaces this file's ingress
  # (and an empty remote ingress is replaced with defaults that 503
  # everything) — but without this file a restart is a 503 window.
  # See the file for the reasoning; keep it in sync with the dashboard.
  configFile = ./cloudflared.yml;
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
        # --config is a global flag and must precede the `tunnel` subcommand.
        ExecStart = "${lib.getExe pkgs.cloudflared} --no-autoupdate --config ${configFile} --metrics 127.0.0.1:20241 tunnel run --token-file %d/tunnel-token";
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
