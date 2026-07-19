# Couch media & streaming apps for the HTPC.
{ config, lib, pkgs, ... }:

let
  # Kodi is our Jellyfin front-end. It is the only client that gives a full
  # 10-foot browse UI *and* real HDR playback on Linux:
  #   * Jellyfin Media Player (the old Qt "jellyfin-desktop") was archived in
  #     2026 and never supported HDR on Linux — its HDR path is Windows-only.
  #     The nixpkgs alias for it also drags in an out-of-date Qt engine that can
  #     flash brightly on Wayland, so we're off it entirely.
  #   * The HDR-capable rewrite (CEF + a forked libmpv with gpu-next/Vulkan/
  #     Wayland passthrough) is unofficial, nightly-only, and unpackaged.
  # kodi-wayland is the ONLY Kodi variant that can output HDR (x11 and gbm
  # cannot), and the `jellyfin` add-on (Jellyfin for Kodi) syncs the library
  # into Kodi's own native UI so browsing feels first-class.
  #
  # TLS note: the add-on verifies certs by default and uses Kodi's bundled
  # Python/certifi, so trust for our private-CA cert comes from the
  # environment.sessionVariables set further down — not from anything here.
  kodiJellyfin = pkgs.kodi-wayland.withPackages (p: with p; [ jellyfin ]);

  # One-click HDR launch: nest Kodi inside gamescope so the HDR swapchain is
  # managed for us, independent of the session-wide Plasma HDR toggle. Capped at
  # 60 Hz for the same 4K60 clean-picture reason documented in desktop.nix
  # (native HDMI is stuck at 2.0 bandwidth until amdgpu FRL lands in Linux 7.2).
  #
  # The output *and* nested-render resolutions are pinned to native 4K: with
  # only `-f` gamescope defaults its internal render size to 1280x720 and
  # upscales, so Kodi's whole UI comes out at 720p. Setting --nested-width/height
  # makes Kodi render its skin at full 3840x2160.
  #
  # If gamescope's nested HDR ever misbehaves, launch Kodi's own plain tile
  # instead — it runs directly in the Plasma session as a fallback.
  kodiHdr = pkgs.writeShellScriptBin "kodi-hdr" ''
    exec ${pkgs.gamescope}/bin/gamescope \
      --hdr-enabled \
      --output-width 3840 --output-height 2160 \
      --nested-width 3840 --nested-height 2160 \
      --nested-refresh 60 \
      -f -- ${kodiJellyfin}/bin/kodi "$@"
  '';

  # Bigscreen/SDDM tile so it launches from the couch UI without a terminal.
  kodiHdrDesktop = pkgs.makeDesktopItem {
    name = "kodi-hdr";
    desktopName = "Kodi (HDR)";
    comment = "Jellyfin front-end with HDR passthrough via gamescope";
    exec = "${kodiHdr}/bin/kodi-hdr";
    icon = "kodi";
    categories = [ "AudioVideo" "Video" "Player" "TV" ];
  };
in
{
  environment.systemPackages = with pkgs; [
    vacuum-tube           # YouTube "TV"/leanback interface (attr is hyphenated)
    moonlight-qt          # game-streaming client (Vulkan renderer, needed for HDR)
    kodiJellyfin          # Kodi (Wayland) + Jellyfin add-on: browse UI + HDR playback
    kodiHdr               # `kodi-hdr` launcher: Kodi nested in gamescope w/ HDR
    kodiHdrDesktop        # "Kodi (HDR)" tile for the Bigscreen couch UI
    mpv
    firefox
  ];

  # Kodi bundles its own Python + certifi, which ignore the system CA trust
  # store — so the Jellyfin add-on (which verifies TLS by default) can't
  # validate the private-CA cert on jellyfin.nasa.jmalexan.com and the
  # connection fails. Point its TLS stack (Python `requests` and libcurl) at the
  # system bundle, which trust-private-ca.nix has already populated with our CA.
  # This is what actually makes the connection work; same fix as the Home
  # Assistant container in hosts/nasa/services/homeassistant.nix.
  environment.sessionVariables = {
    SSL_CERT_FILE      = "/etc/ssl/certs/ca-certificates.crt";
    REQUESTS_CA_BUNDLE = "/etc/ssl/certs/ca-certificates.crt";
    CURL_CA_BUNDLE     = "/etc/ssl/certs/ca-certificates.crt";
  };

  # gamescope is the cleanest way to get HDR for a single app without fighting
  # the session-wide toggle, e.g.:
  #   gamescope --hdr-enabled --nested-refresh 120 -f -- moonlight
  # (the `kodi-hdr` launcher above wraps Kodi this way for you).
  programs.gamescope = {
    enable = true;
    capSysNice = true;
  };
}
