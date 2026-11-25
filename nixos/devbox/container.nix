# The NixOS configuration inside every devbox. Only what every devbox needs:
# the developer account, key-only sshd, Nix with flakes, and a few base tools.
#
# Project tooling does not belong here. Each project brings its own through
# its flake (`nix develop`), so a devbox never accumulates one project's tools.
{ config, lib, pkgs, ... }:

let
  cfg = config.tux.devbox;
in
{
  # Set by ./default.nix from the devbox's entry in `tux.devboxes`.
  options.tux.devbox = {
    user = lib.mkOption { type = lib.types.str; internal = true; };
    uid = lib.mkOption { type = lib.types.int; internal = true; };
    sshPort = lib.mkOption { type = lib.types.port; internal = true; };
    authorizedKeys = lib.mkOption { type = lib.types.listOf lib.types.str; internal = true; };
  };

  config = {
    system.stateVersion = "25.11";

    # Accounts come from this file only. The account has no password; keys are
    # the only way in.
    users.mutableUsers = false;
    # Root inside a devbox is reached only from the host (`nixos-container
    # root-login`, `machinectl shell`), which needs no password or key here.
    users.allowNoPasswordLogin = true;
    users.users.${cfg.user} = {
      isNormalUser = true;
      uid = cfg.uid;
      group = "users";
      home = "/home/${cfg.user}";
      createHome = false; # the home is a bind-mounted dataset
      shell = pkgs.zsh;
      hashedPassword = "!";
      openssh.authorizedKeys.keys = cfg.authorizedKeys;
    };

    services.openssh = {
      enable = true;
      ports = [ cfg.sshPort ];
      settings = {
        PasswordAuthentication = false;
        KbdInteractiveAuthentication = false;
        PermitRootLogin = "no";
      };
    };

    # The devbox shares the host's network namespace, so a firewall here would
    # rewrite the host's rules. The host's firewall is the only one.
    networking.firewall.enable = false;

    nix.settings.experimental-features = [ "nix-command" "flakes" ];

    programs.zsh.enable = true;
    programs.direnv.enable = true;

    environment.systemPackages = with pkgs; [
      bubblewrap # relay's job sandbox
      curl
      git
      rsync
    ];
  };
}
