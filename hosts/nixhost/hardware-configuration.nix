# PLACEHOLDER — replace this file with the output of:
#
#   nixos-generate-config --show-hardware-config
#
# Run that command on the target machine (from the NixOS installer or a
# running NixOS system) and paste the result here before deploying.
{ lib, modulesPath, ... }:

{
  # Bare minimum so the flake evaluates before the real hardware config is in place.
  nixpkgs.hostPlatform = lib.mkDefault "x86_64-linux";
}
