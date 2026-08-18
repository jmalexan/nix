{ pkgs, vars, ... }:

let
  wake-htpc = pkgs.writeShellApplication {
    name = "wake-htpc";
    runtimeInputs = [ pkgs.wakeonlan ];
    text = ''
      exec wakeonlan 38:05:25:36:95:8f
    '';
  };
in
{
  imports = [
    ./hardware-configuration.nix
    ./permissions.nix
    ./containers/home.nix
    ./services
  ];

  boot.supportedFilesystems = [ "zfs" ];
  boot.zfs.forceImportRoot = false;
  boot.zfs.extraPools = [ "Data" ];

  # ZFS ARC limits — host has 32 GiB RAM
  boot.extraModprobeConfig = ''
    options zfs zfs_arc_max=17179869184
    options zfs zfs_arc_min=2147483648
  '';

  networking.hostName = "nasa";
  networking.hostId = "e878c22f";

  programs.nix-ld.enable = true;

  # Same-LAN relay for deployments: an ephemeral GitHub runner cannot send a
  # broadcast packet through Tailscale, while this always-on host can.
  environment.systemPackages = [ wake-htpc ];

  users.users.${vars.user.name}.extraGroups = [
    "hass"
    "jellyfin"
    "qbittorrent"
    "immich"
    "media"
  ];

  # Set when this host was installed; do not change during upgrades.
  system.stateVersion = "25.11";
  age.identityPaths = [ "/etc/age/host.key" ];
}
