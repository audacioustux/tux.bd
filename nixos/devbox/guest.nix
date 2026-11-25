# The inside of every devbox: the developer account, key-only sshd, Nix with
# flakes, optional Docker, and a few base tools. Nothing project-specific:
# projects bring their own tools (mise, Nix shells) into the home and
# workspaces, which outlive the VM.
#
# The VM's root filesystem is a tmpfs, rebuilt from this file on every start.
# Only /var (a disk image) and the shared datasets persist; see ./default.nix.
{ config, lib, pkgs, ... }:

let
  cfg = config.tux.devbox;
in
{
  # Set by ./default.nix from the devbox's entry in `tux.devboxes`.
  options.tux.devbox = with lib.types; {
    user = lib.mkOption { type = str; };
    uid = lib.mkOption { type = int; };
    authorizedKeys = lib.mkOption { type = listOf str; };
    docker = lib.mkOption { type = bool; };
  };

  config = {
    system.stateVersion = "25.11";

    # The account is declared here in full; nothing inside the VM adds users.
    users.mutableUsers = false;
    users.users.${cfg.user} = {
      isNormalUser = true;
      inherit (cfg) uid;
      group = "users";
      home = "/home/${cfg.user}";
      createHome = false; # the home is the shared home dataset
      shell = pkgs.zsh;
      hashedPassword = "!"; # keys only
      extraGroups = [ "wheel" ] ++ lib.optional cfg.docker "docker";
      openssh.authorizedKeys.keys = cfg.authorizedKeys;
    };
    # The VM is the isolation boundary, so the developer is root inside it,
    # as in a devcontainer.
    security.sudo.wheelNeedsPassword = false;

    services.openssh = {
      enable = true;
      # On /var, so the host key survives restarts.
      hostKeys = [ { path = "/var/lib/ssh/ssh_host_ed25519_key"; type = "ed25519"; } ];
      settings = {
        PasswordAuthentication = false;
        KbdInteractiveAuthentication = false;
        PermitRootLogin = "no";
      };
    };

    # Containers for projects that simulate clusters. Rootful is fine: the VM
    # holds it. Its data is under /var, so images survive restarts.
    virtualisation.docker.enable = cfg.docker;

    nix.settings = {
      experimental-features = [ "nix-command" "flakes" ];
      trusted-users = [ cfg.user ];
    };

    # Prebuilt toolchains that mise and rustup download expect a standard
    # Linux loader; nix-ld provides it.
    programs.nix-ld.enable = true;
    programs.zsh.enable = true;
    programs.direnv.enable = true;

    # bubblewrap: relay's job sandbox. perf: hardware counters (the VM gets
    # the host CPU's PMU). mise: the tool manager projects and the developer's
    # global tools (~/.config/mise) are declared in.
    environment.systemPackages = with pkgs; [
      bubblewrap
      curl
      git
      mise
      perf
      rsync
    ];
  };
}
