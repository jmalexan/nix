# Machine-specific configuration for "nix".
# Place (or symlink) this host's hardware-configuration.nix alongside this file.
{ ... }: {
  imports = [ ./hardware-configuration.nix ];

  networking.hostName = "nix";
}
