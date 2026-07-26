{ config, pkgs, lib, ... }:

let
  # ── Remote-friendly mpv bindings ────────────────────────────────────────────
  # The Skip 1s reaches mpv as plain keystrokes via the Flirc USB; the mapping
  # from remote button to key lives in hosts/htpc/remote.nix, and this file is
  # the other half — what those keys should *do* in the player.
  #
  # Only bindings that differ from mpv's defaults, or that cover keys mpv leaves
  # alone, are listed. Notably:
  #   • ESC defaults to "leave fullscreen", which is wrong for a remote's Back
  #     button on a TV — you end up in a windowed player with no pointer.
  #   • ENTER is unbound by default, but OK/Select is the button anyone reaches
  #     for to pause.
  #   • F13-F17 are the keys remote.nix assigns to Skip/Info/Subtitle/Audio,
  #     picked because nothing else on the system claims them.
  mpvInputConf = ''
    # Managed by home/htpc.nix — see hosts/htpc/remote.nix for the remote map.

    # D-pad. Wider steps than mpv's 5s/60s defaults; 10s suits a TV better.
    LEFT      seek -10
    RIGHT     seek  10
    UP        seek  60
    DOWN      seek -60

    # OK / Select.
    ENTER     cycle pause

    # Back. Stop playback rather than dropping out of fullscreen. For
    # jellyfin-mpv-shim this releases the cast session and idles the player.
    ESC       stop

    # Transport keys the Flirc emits as consumer/media usages.
    PLAYPAUSE cycle pause
    PLAY      set pause no
    PAUSE     set pause yes
    STOP      stop
    REWIND    seek -60
    FORWARD   seek  60
    NEXT      playlist-next
    PREV      playlist-prev

    # Dedicated Skip buttons — the remote's namesake, sized for intros/ads.
    F13       seek -30
    F14       seek  30

    # Info / Subtitle / Audio.
    F15       show-progress
    F16       cycle sub
    F17       cycle audio
  '';
in
{
  imports = [ ./linux.nix ];

  # Standalone mpv (apps.nix installs it system-wide, so just drop the config in
  # rather than pulling a second copy in through programs.mpv).
  xdg.configFile."mpv/input.conf".text = mpvInputConf;

  # jellyfin-mpv-shim embeds mpv and reads mpv.conf/input.conf from its own
  # config directory, alongside the conf.json that apps.nix describes. Only
  # input.conf is managed here — conf.json holds the server URL and auth token
  # and stays runtime-owned.
  #
  # The shim also layers its own keybinds on top (kb_* in conf.json). The one
  # worth knowing from the couch is `c`, which opens the shim's on-screen menu —
  # track selection and library browsing, i.e. the browse UI the shim otherwise
  # lacks. remote.nix puts that on a spare colour-wheel button.
  xdg.configFile."jellyfin-mpv-shim/input.conf".text = mpvInputConf;
}
