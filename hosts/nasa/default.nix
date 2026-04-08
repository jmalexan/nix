# Machine-specific configuration for "nasa" (bare-metal NixOS host).
# Replace hardware-configuration.nix with the output of nixos-generate-config
# after booting the NixOS installer on this machine.
{ ... }: {
  imports = [ ./hardware-configuration.nix ];

  boot.supportedFilesystems = [ "zfs" ];
  boot.zfs.forceImportRoot = false;
  boot.zfs.extraPools = [ "Data" ];

  networking.hostName = "nasa";
  networking.hostId = "e878c22f";

  # Enable KVM/libvirt so this host can run the NixOS VM (and others).
  virtualisation.libvirtd.enable = true;
  programs.virt-manager.enable = true;
}
