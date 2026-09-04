# Couch media & streaming apps for the HTPC.
{
  pkgs,
  ...
}:

let
  # Keep the network wait in the service's main process, not ExecStartPre.
  # During a NixOS switch NetworkManager is stopped while Home Manager reloads
  # user services; blocking their startup on nm-online prevents the switch from
  # reaching the later step that starts NetworkManager again. A Type=simple
  # service is considered started while this wrapper waits, breaking that
  # ordering cycle while retaining the boot-time connectivity guard.
  jellyfinMpvShimService = pkgs.writeShellApplication {
    name = "jellyfin-mpv-shim-service";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.jellyfin-mpv-shim
      pkgs.networkmanager
    ];
    text = ''
      until nm-online -q -t 5; do
        sleep 5
      done
      exec jellyfin-mpv-shim
    '';
  };
in
{
  environment.systemPackages = with pkgs; [
    vacuum-tube # YouTube "TV"/leanback interface (attr is hyphenated)
    moonlight-qt # game-streaming client (Vulkan renderer, needed for HDR)
    mpv
    firefox
  ];

  # jellyfin-mpv-shim is our Jellyfin player: an mpv-based cast target (mpv has
  # the strongest HDR engine on Linux). It runs headless — no browse UI of its
  # own — so you play by casting to it from another Jellyfin client (phone/web).
  # Kept as a self-healing user service rather than a CLI on PATH: it renders
  # mpv into the Wayland session, so it's tied to graphical-session (up with the
  # desktop, down on logout) and restarted if it dies. Its settings live in
  # ~/.config/jellyfin-mpv-shim/conf.json, and the ones this host has an opinion
  # about — transcoding policy, seek steps, the `c` menu key — are declared in
  # home/htpc.nix and merged into that file on every activation; restart the
  # service to pick them up. What stays runtime-owned is users.json beside it,
  # which is where the server URL and access token actually live — conf.json
  # holds no credentials. The player's mpv config is declared in home/htpc.nix
  # too (input.conf for the Skip 1s remote, mpv.conf for the HDR output path),
  # so the remote drives the player sensibly. The shim's own `c` menu is the
  # closest thing it has to a browse UI, so the remote gets it.
  systemd.user.services.jellyfin-mpv-shim = {
    description = "Jellyfin MPV Shim cast target";
    after = [ "graphical-session.target" ];
    partOf = [ "graphical-session.target" ];
    wantedBy = [ "graphical-session.target" ];
    serviceConfig = {
      # The autologin session (desktop.nix) is up seconds into boot, while
      # NetworkManager is still doing DHCP — so the shim used to start with no
      # resolv.conf yet, fail to resolve the server's hostname, and log its way
      # through a few restart cycles before the link settled. The wrapper waits
      # until NetworkManager reports connectivity, i.e. DHCP and DNS are ready.
      # It is intentionally ExecStart rather than ExecStartPre; see above.
      ExecStart = "${jellyfinMpvShimService}/bin/jellyfin-mpv-shim-service";
      Restart = "always";
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
