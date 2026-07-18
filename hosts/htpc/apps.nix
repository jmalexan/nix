# Couch media & streaming apps for the HTPC.
{ config, lib, pkgs, ... }:

{
  environment.systemPackages = with pkgs; [
    vacuum-tube           # YouTube "TV"/leanback interface (attr is hyphenated)
    moonlight-qt          # game-streaming client (Vulkan renderer, needed for HDR)
    jellyfin-media-player # Jellyfin couch client (alias -> jellyfin-desktop v2 on 25.11)
    # jellyfin-mpv-shim   # alternative: mpv-based, strongest HDR playback engine
    mpv
  ];

  # gamescope is the cleanest way to get HDR for a single app without fighting
  # the session-wide toggle, e.g.:
  #   gamescope --hdr-enabled --nested-refresh 120 -f -- moonlight
  programs.gamescope = {
    enable = true;
    capSysNice = true;
  };
}
