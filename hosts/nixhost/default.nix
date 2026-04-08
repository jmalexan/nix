# Machine-specific configuration for "nixhost" (bare-metal NixOS host).
# Replace hardware-configuration.nix with the output of nixos-generate-config
# after booting the NixOS installer on this machine.
{ ... }: {
  imports = [ ./hardware-configuration.nix ];

  networking.hostName = "nixhost";

  # Enable KVM/libvirt so this host can run the NixOS VM (and others).
  virtualisation.libvirtd.enable = true;
  programs.virt-manager.enable = true;
}
