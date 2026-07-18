{ config, lib, pkgs, ... }:

{
  imports = [
    ./hardware-configuration.nix
    ./desktop.nix
    ./apps.nix
    ./controller.nix
  ];

  networking.hostName = "htpc";

  # ── Kernel ──────────────────────────────────────────────────────────────────
  # Latest stable mainline for the newest amdgpu + HDR colour-pipeline work on
  # the Radeon 780M (RDNA3). NOTE on 4K120 over HDMI: native HDMI 2.1 FRL is an
  # amdgpu feature that only landed in the Linux 7.2 merge window, is DISABLED by
  # default, and is still under review. Until a 7.2+ kernel is in nixpkgs the
  # native HDMI port tops out at HDMI 2.0 bandwidth (4K120 needs 4:2:0 chroma,
  # which bands) — for full 4:4:4 4K120/HDR today, use a USB4/DP-alt → HDMI 2.1
  # active adapter. Once on a 7.2+ kernel, uncomment the kernelParams line below
  # to turn native FRL on.
  boot.kernelPackages = pkgs.linuxPackages_latest;
  # boot.kernelParams = [ "amdgpu.dc_feature_mask=0x400" ];

  # ── GPU ─────────────────────────────────────────────────────────────────────
  # amdgpu loads via KMS automatically; no services.xserver.videoDrivers needed
  # for the Plasma 6 Wayland session. 32-bit libs are handy for gamescope/streaming.
  hardware.graphics = {
    enable = true;
    enable32Bit = true;
  };
  hardware.enableRedistributableFirmware = true;
}
