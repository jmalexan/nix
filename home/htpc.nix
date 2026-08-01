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
  #     picked because nothing else on the system claims them. Nothing else
  #     does — but they only reach mpv as F13-F17 with the keymap option set
  #     in `xdg.configFile."kxkbrc"` below. Without it xkeyboard-config hands
  #     those keycodes to vendor hotkey keysyms and these five lines are dead.
  mpvInputConf = ''
    # Managed by home/htpc.nix — see hosts/htpc/remote.nix for the remote map.

    # D-pad. Wider steps than mpv's 5s/60s defaults; 10s suits a TV better.
    LEFT      seek -10
    RIGHT     seek  10
    UP        seek  60
    DOWN      seek -60

    # OK / Select. remote.nix pairs this button with Return, so ENTER is the one
    # that fires; KP_ENTER is insurance in case a button ever gets recorded with
    # flirc's `record enter`, which emits keypad Enter instead. mpv, like Qt,
    # treats the two as distinct keys.
    ENTER     cycle pause
    KP_ENTER  cycle pause

    # Back. Stop playback rather than dropping out of fullscreen. For
    # jellyfin-mpv-shim this releases the cast session and idles the player.
    ESC       stop

    # Transport keys the Flirc emits as consumer/media usages.
    #
    # PLAY is the one that fires, and it has to toggle. The Flirc's play/pause
    # sends the HID consumer Play/Pause usage, which the kernel turns into
    # KEY_PLAYPAUSE and xkeyboard-config maps to XF86AudioPlay — i.e. mpv's
    # PLAY. There is no evdev path to mpv's PLAYPAUSE at all, so binding this
    # to `set pause no` (as it was) meant the button could only ever resume:
    # pressing it during playback did nothing. PLAYPAUSE stays as insurance for
    # backends that do emit it (Windows, macOS); PAUSE is XF86AudioPause, which
    # is shift-level-2 of the same key and unreachable from the remote.
    PLAYPAUSE cycle pause
    PLAY      cycle pause
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

  # ── Make F13-F24 exist at all ───────────────────────────────────────────────
  # The Flirc sends real HID F13-F17 usages and the kernel turns them into
  # KEY_F13-KEY_F17, but the *keymap* is where they die: xkeyboard-config's
  # default `inet(evdev)` symbols reuse those keycodes for vendor hotkeys —
  # FK13 becomes XF86Tools and FK14-FK18 become XF86Launch5-XF86Launch9. mpv
  # knows XF86Tools as TOOLS and has no name at all for XF86Launch*, so every
  # F13-F17 line in input.conf above silently never fires. `fkeys:basic_13-24`
  # is the xkeyboard-config option that maps FK13-FK24 back to plain F13-F24.
  #
  # This has to be a user-level file rather than `services.xserver.xkb.options`:
  # that NixOS option only reaches Xorg and systemd-localed, and kwin_wayland
  # consults locale1 only when started with --locale1 or when kwinrc has
  # `[Wayland] FollowLocale1=true` (default false). Otherwise KWin builds its
  # keymap from kxkbrc — and reads Options only when ResetOldOptions is set
  # (kwin/src/xkb.cpp, loadKeymapFromConfig).
  #
  # Nothing outside FK13-FK24 moves — the cost is the vendor hotkeys those
  # keycodes carried (XF86Tools, XF86Launch5-9, XF86AudioMicMute and the
  # XF86Touchpad* trio), none of which exist on a keyboardless HTPC.
  #
  # Layout and variant are left empty on purpose so the normal defaults still
  # apply; this file carries the option and nothing else. It is a store symlink
  # and therefore read-only, so Plasma's keyboard KCM can no longer save here —
  # harmless on a box with no keyboard, but the reason to keep it this small.
  # Takes effect at the next login: KWin compiles the keymap once at startup.
  xdg.configFile."kxkbrc".text = ''
    [Layout]
    Options=fkeys:basic_13-24
    ResetOldOptions=true
  '';

  # ── Give the media keys back to the focused player ──────────────────────────
  # Plasma's MPRIS KDED module (plasma-workspace, libkmpris/kded) autoloads in
  # every Plasma session, Bigscreen included, and its constructor unconditionally
  # registers KGlobalAccel shortcuts on exactly the keysyms this remote sends:
  #
  #   playpausemedia ...... Key_MediaPlay   ← XF86AudioPlay    ← PLAY / PAUSE
  #   stopmedia ........... Key_MediaStop   ← XF86AudioStop    ← STOP
  #   seekforwardmedia .... Key_AudioForward ← XF86AudioForward ← FAST FORWARD
  #   seekbackwardmedia ... Key_AudioRewind  ← XF86AudioRewind  ← REWIND
  #
  # KWin resolves global shortcuts before forwarding a key to the focused
  # window, so those four buttons never reached mpv — and the module then did
  # nothing with them either, because it drives players over MPRIS and mpv
  # publishes no MPRIS interface here. Hence four dead buttons.
  #
  # Clearing the assignments lets the keys fall through to whatever has focus,
  # which is what the mpv bindings above have always assumed. The alternative
  # would be to load mpvScripts.mpris so the grabs actually control the player;
  # that also survives mpv not having focus, but hands the seek step to KDE
  # (fixed 5s / 30s) and gives up the 60s steps this remote is built around.
  #
  # Written with kwriteconfig6 rather than xdg.configFile because kglobalacceld
  # rewrites kglobalshortcutsrc itself — every component that registers an
  # action persists it there — and a read-only store symlink would break that.
  # The daemon caches shortcuts in memory, so this lands at the next login (or
  # after `systemctl --user restart plasma-kglobalaccel`).
  home.activation.freeRemoteMediaKeys =
    lib.hm.dag.entryAfter [ "writeBoundary" ] ''
      kwriteconfig=${pkgs.kdePackages.kconfig}/bin/kwriteconfig6
      for action in playpausemedia stopmedia seekforwardmedia seekbackwardmedia; do
        run "$kwriteconfig" --file kglobalshortcutsrc \
          --group mediacontrol --key "$action" "none,none,$action"
      done
    '';
}
