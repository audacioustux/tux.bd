# OpenZFS 2.4.4 (Linux 4.18 to 7.2) through this system's own nixpkgs ZFS recipe. The 25.11
# channel ships 2.4.2 (to 7.0); nixos-unstable's 2.4.4 links against a newer glibc than
# this system's, which the initrd refuses. Drop this file once the channel's zfs_2_4
# supports the kernel in use. See configuration.nix (Kernel 7.2).
{
  callPackage,
  pkgs,
  ...
}@args:

callPackage "${pkgs.path}/pkgs/os-specific/linux/zfs/generic.nix" (builtins.removeAttrs args [ "pkgs" ]) {
  kernelModuleAttribute = "zfs_2_4";
  kernelMinSupportedMajorMinor = "4.18";
  kernelMaxSupportedMajorMinor = "7.2";
  version = "2.4.4";
  hash = "sha256-ZgfHTPsNoeDq6GKP4Xiti7Keis3vIZLDaTGQjgCItIc=";
  extraPatches = [ ];
  tests = { };
  maintainers = [ ];
}
