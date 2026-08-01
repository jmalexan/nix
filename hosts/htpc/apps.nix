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
  # Its mpv keybindings are the exception — those are declared in home/htpc.nix
  # so the Skip 1s remote (remote.nix) drives the player sensibly. The shim's own
  # `c` menu is the closest thing it has to a browse UI, so the remote gets it.
  systemd.user.services.jellyfin-mpv-shim = {
    description = "Jellyfin MPV Shim cast target";
    after    = [ "graphical-session.target" ];
    partOf   = [ "graphical-session.target" ];
    wantedBy = [ "graphical-session.target" ];
    serviceConfig = {
      # The autologin session (desktop.nix) is up seconds into boot, while
      # NetworkManager is still doing DHCP — so the shim used to start with no
      # resolv.conf yet, fail to resolve the server's hostname, and log its way
      # through a few restart cycles before the link settled. A user unit can't
      # order itself after the system's network-online.target (the user manager
      # can't see system units), so block here instead: nm-online exits as soon
      # as NetworkManager reports connectivity, i.e. DHCP is done and DNS is
      # usable. The 60s cap stays under the 90s default TimeoutStartSec; if it
      # ever expires, Restart=always just tries again 5s later.
      ExecStartPre = "${pkgs.networkmanager}/bin/nm-online -q -t 60";
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
