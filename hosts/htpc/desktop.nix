# KDE Plasma 6 (Wayland) with the Plasma Bigscreen 10-foot shell as the default
# session, autologin straight to the couch UI.
#
# Bigscreen was re-ported to Qt6/Plasma 6 and ships as kdePackages.plasma-bigscreen
# 6.7.x — but ONLY on nixos-unstable (stable 26.05 is still Plasma 6.6). That's why
# this host is built from nixpkgs-unstable in flake.nix. The base Plasma 6 desktop
# is still enabled underneath, so you can drop to a normal "Plasma (Wayland)"
# session from SDDM if Bigscreen ever misbehaves.
{ config, lib, pkgs, ... }:

{
  services.displayManager.sddm = {
    enable = true;
    wayland.enable = true;
  };
  services.desktopManager.plasma6.enable = true;

  # Register the Bigscreen Wayland session and make it the default.
  services.displayManager.sessionPackages = [ pkgs.kdePackages.plasma-bigscreen ];

  # Boot straight into Bigscreen on the TV.
  services.displayManager.autoLogin = {
    enable = true;
    user = "jmalexan";
  };
  # Session id from plasma-bigscreen's providedSessions. To fall back to the plain
  # desktop, set this to "plasma" (or disable autoLogin and pick it at the greeter).
  services.displayManager.defaultSession = "plasma-bigscreen-wayland";

  # Audio over HDMI (and everything else). plasma6 pulls PipeWire in, but be explicit.
  services.pulseaudio.enable = false;
  security.rtkit.enable = true;
  services.pipewire = {
    enable = true;
    alsa.enable = true;
    alsa.support32Bit = true;
    pulse.enable = true;
  };

  # ── HDR & 4K60 (banding workaround) ──────────────────────────────────────────
  # Both the display mode and HDR are *runtime* settings on Plasma 6 — there is no
  # build-time NixOS toggle. Set them in System Settings > Display, or via shell.
  #
  # Until amdgpu HDMI 2.1 FRL lands (Linux 7.2), the native HDMI port is capped at
  # HDMI 2.0 bandwidth. At 4K120 the driver is forced to 4:2:0 chroma (visible
  # banding). At *4K60* it fits full 8-bit RGB 4:4:4 for SDR (no banding), and
  # clean 10-bit 4:2:2 for HDR — chroma is chosen automatically, so simply
  # capping the refresh rate at 60 Hz is the fix:
  #   kscreen-doctor -o                                     # list outputs / names
  #   kscreen-doctor output.HDMI-A-1.mode.3840x2160@60
  #   kscreen-doctor output.HDMI-A-1.hdr.enable output.HDMI-A-1.wcg.enable
  #
  # Plasma sometimes resets these across output changes; to pin them every login
  # uncomment and set the real output name (from `kscreen-doctor -o`, e.g. HDMI-A-1):
  #
  # systemd.user.services.tv-output = {
  #   description = "Pin TV to 4K60 + HDR (clean picture until HDMI 2.1 FRL lands)";
  #   wantedBy = [ "graphical-session.target" ];
  #   partOf   = [ "graphical-session.target" ];
  #   serviceConfig = {
  #     Type = "oneshot";
  #     ExecStart = "${pkgs.kdePackages.libkscreen}/bin/kscreen-doctor "
  #       + "output.HDMI-A-1.mode.3840x2160@60 "
  #       + "output.HDMI-A-1.hdr.enable output.HDMI-A-1.wcg.enable";
  #   };
  # };

  # ── Idle & wake-on-controller ────────────────────────────────────────────────
  # We deliberately do NOT S3-suspend the machine: a Bluetooth controller cannot
  # wake a suspended PC. Instead the box stays powered and only the *display*
  # sleeps (DPMS). When you turn the controller on it re-pairs and the first input
  # wakes the screen — console-like, and it works over Bluetooth. Make "never auto
  # suspend on idle" explicit at the system level (Plasma also won't auto-suspend
  # on AC by default; it just blanks the screen):
  services.logind.settings.Login.IdleAction = "ignore";
  # If you later want true low-power S3 suspend with wake, the only reliable path
  # is the Xbox Wireless Dongle (USB wake) — enable hardware.xone.enable and the
  # wake udev rule in controller.nix. Bluetooth cannot do it.
}
