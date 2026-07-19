# Couch media & streaming apps for the HTPC.
{ config, lib, pkgs, ... }:

{
  environment.systemPackages = with pkgs; [
    vacuum-tube           # YouTube "TV"/leanback interface (attr is hyphenated)
    moonlight-qt          # game-streaming client (Vulkan renderer, needed for HDR)
    mpv
    firefox
  ];

  # jellyfin-mpv-shim is our Jellyfin player: an mpv-based cast target (mpv has
  # the strongest HDR engine on Linux). It runs headless — no browse UI of its
  # own — so you play by casting to it from another Jellyfin client (phone/web).
  # Kept as a self-healing user service rather than a CLI on PATH: it renders
  # mpv into the Wayland session, so it's tied to graphical-session (up with the
  # desktop, down on logout) and restarted if it dies. Its config — the LAN HTTP
  # server URL and the disabled GUI/menu — lives in
  # ~/.config/jellyfin-mpv-shim/conf.json; restart the service to pick up edits.
  systemd.user.services.jellyfin-mpv-shim = {
    description = "Jellyfin MPV Shim cast target";
    after    = [ "graphical-session.target" ];
    partOf   = [ "graphical-session.target" ];
    wantedBy = [ "graphical-session.target" ];
    serviceConfig = {
      ExecStart  = "${pkgs.jellyfin-mpv-shim}/bin/jellyfin-mpv-shim";
      Restart    = "always";
      RestartSec = 5;
    };
  };

  # gamescope is the cleanest way to get HDR for a single app without fighting
  # the session-wide toggle, e.g.:
  #   gamescope --hdr-enabled --nested-refresh 120 -f -- moonlight
  programs.gamescope = {
    enable = true;
    capSysNice = true;
  };
}
