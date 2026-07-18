# Hardware config for the Minisforum UM760 (AMD Ryzen 7 7840HS / Radeon 780M).
#
# Disk partitioning and filesystems are declarative via disko (hosts/htpc/disko.nix),
# so there is intentionally no `fileSystems` block here. You can still regenerate the
# kernel-module lines on the real box with:
#   nixos-generate-config --show-hardware-config
# but keep disko as the source of truth for partitions — do NOT copy its generated
# fileSystems entries in here (that would double-define them). Re-add the amdgpu
# initrd module below if the generator drops it (early KMS gives a clean HDR handoff).
{ config, lib, pkgs, modulesPath, ... }:

{
  imports = [ (modulesPath + "/installer/scan/not-detected.nix") ];

  boot.initrd.availableKernelModules = [ "nvme" "xhci_pci" "thunderbolt" "usbhid" "usb_storage" "sd_mod" ];
  boot.initrd.kernelModules = [ "amdgpu" ];
  boot.kernelModules = [ "kvm-amd" ];
  boot.extraModulePackages = [ ];

  # Partitions and filesystems live in hosts/htpc/disko.nix.
  swapDevices = [ ];

  nixpkgs.hostPlatform = lib.mkDefault "x86_64-linux";
  hardware.cpu.amd.updateMicrocode = lib.mkDefault config.hardware.enableRedistributableFirmware;
}
