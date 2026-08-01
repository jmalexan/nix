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

  # ── Playback settings ───────────────────────────────────────────────────────
  # Shared by standalone mpv and the mpv that jellyfin-mpv-shim embeds. The shim
  # starts its player with `config=yes` and `config_dir` pointed at its own
  # config directory (player.py, build_mpv_options), so the same text has to be
  # dropped in both places — it does not read ~/.config/mpv.
  #
  # This is the player half of the HDR work desktop.nix does at the compositor
  # level. Nothing here was previously declared, so until now the box played
  # back on mpv's stock defaults.
  mpvConfCommon = ''
    # Managed by home/htpc.nix.

    # ── Video output ──────────────────────────────────────────────────────────
    # gpu-next is the libplacebo-backed VO and the only one that can hand HDR
    # metadata to the compositor rather than tone-mapping to SDR itself; vulkan
    # is its native API on amdgpu.
    vo=gpu-next
    gpu-api=vulkan

    # The line that actually makes HDR content light up the TV: mpv asks KWin to
    # put the output into HDR for the duration of an HDR file and back
    # afterwards, instead of squashing it to SDR in the player. Requires the
    # Wayland colour-management protocol, which Plasma 6.7 (desktop.nix) has.
    target-colorspace-hint=yes

    # VAAPI on the Radeon 780M. auto-safe rather than a hard `vaapi` so a codec
    # the iGPU can't actually decode falls back to software instead of failing
    # to play at all — AV1 and 8-bit/10-bit HEVC are fine, older oddities aren't.
    hwdec=auto-safe

    # Deliberately no `profile=high-quality`: its scaler chain is sized for a
    # discrete GPU and would drop frames on a 780M at 4K, which is the one
    # resolution this box exists to play.

    # ── Network buffering ─────────────────────────────────────────────────────
    # Everything here arrives over HTTP from nasa. mpv's defaults are sized for
    # 2 Mbit web video; a 4K remux wants a much deeper buffer to ride out a
    # hiccup on the LAN without stuttering.
    cache=yes
    demuxer-max-bytes=250MiB
    demuxer-max-back-bytes=100MiB

    # ── Audio ─────────────────────────────────────────────────────────────────
    # Decoding is left to mpv and PipeWire rather than bitstreamed: this box is
    # wired straight to the TV, and passthrough only pays off into a receiver
    # that can decode TrueHD/DTS-HD itself. If an AVR ever lands in the chain,
    # this is the line to add:
    #   audio-spdif=ac3,dts,eac3,truehd,dts-hd

    # Subtitles are deliberately absent. jellyfin-mpv-shim drives them from
    # conf.json (subtitle_size / subtitle_color / subtitle_position, applied per
    # track) and a sub-scale set behind its back would fight it.
  '';

  # ── jellyfin-mpv-shim settings ──────────────────────────────────────────────
  # Only the keys this host has an opinion about; everything else stays whatever
  # the shim writes. See the activation script below for why these are merged
  # into the live file rather than symlinked from the store.
  #
  # Field names and defaults checked against jellyfin-mpv-shim 2.10.0, which is
  # what nixpkgs-unstable currently pins.
  jellyfinShimSettings = {
    # ── Don't transcode away the thing this box was built for ─────────────────
    # transcode_dolby_vision is the one that actually changes behaviour: 2.10.0
    # ships it *on*, so the server was re-encoding every Dolby Vision title down
    # to SDR — burning CPU on nasa to throw away the HDR presentation. (Upstream
    # has since flipped the default, having concluded mpv handles DV natively;
    # this pins the good value on the version we run.) The rest already default
    # off and are pinned so a stray press in the shim's settings menu, or a
    # future default change, can't quietly undo them.
    always_transcode = false;
    transcode_hdr = false;
    transcode_dolby_vision = false;
    transcode_hevc = false;
    transcode_hi10p = false;
    transcode_av1 = false;
    transcode_4k = false;

    # ── Seek steps ────────────────────────────────────────────────────────────
    # These are load-bearing, and were wrong. The shim registers its own mpv
    # keybinds for the arrow keys (player.py: kb_menu_left/right/up/down ->
    # kb_seek), and a script binding beats input.conf — so under the shim the
    # D-pad has always used *these* numbers, not the `seek -10` / `seek 10`
    # lines above. Left/right were the shim's 5s default, quietly overriding the
    # 10s that input.conf documents. Matching them here makes the two agree.
    seek_left = -10;
    seek_right = 10;
    seek_up = 60;
    seek_down = -60;

    # The colour-wheel button remote.nix records as `c`. Pinned because the
    # remote's mapping is meaningless if this key moves.
    kb_menu = "c";

    # A cast target has no reason not to take the screen.
    fullscreen = true;

    # No system tray in a Bigscreen session, so the tray/settings GUI has
    # nowhere to appear; the OSD menu on `c` is unaffected (it is the player's,
    # not the GUI manager's).
    enable_gui = false;

    # mpv's own `input-media-keys`, which the shim passes through. Must stay on:
    # the transport buttons reach the player as XF86Audio* keysyms, which is the
    # whole point of the kglobalshortcutsrc surgery below.
    media_keys = true;
    # Leaves PREV/NEXT as playlist prev/next, matching input.conf above.
    media_key_seek = false;

    # The package is nixpkgs'; an in-app update nag is noise on a TV and can
    # only ever point at something we can't install.
    check_updates = false;
    notify_updates = false;
  };
in
{
  imports = [ ./linux.nix ];

  # Standalone mpv (apps.nix installs it system-wide, so just drop the config in
  # rather than pulling a second copy in through programs.mpv).
  xdg.configFile."mpv/input.conf".text = mpvInputConf;
  xdg.configFile."mpv/mpv.conf".text = mpvConfCommon + ''

    # Standalone mpv only. Opened from the TV there is no window to arrange and
    # no pointer to arrange it with, so start fullscreen. Not in the shared
    # block because the shim manages its own window (conf.json `fullscreen`).
    fullscreen=yes
  '';

  # jellyfin-mpv-shim embeds mpv and reads mpv.conf/input.conf from its own
  # config directory, alongside conf.json.
  #
  # The shim also layers its own keybinds on top (kb_* in conf.json), and those
  # *win* over input.conf — they are registered as script bindings after the
  # config is read. Two consequences worth knowing from the couch:
  #   • the D-pad seek steps come from conf.json's seek_* , not from the `seek`
  #     lines above; they are pinned to match in jellyfinShimSettings.
  #   • ESC is bound by the shim to kb_menu_esc, so BACK closes the shim's menu
  #     when it is open and otherwise merely leaves fullscreen — the `ESC stop`
  #     line above never fires under the shim. Freeing it means setting
  #     kb_menu_esc to something the remote can't send, which costs you
  #     "back one level" inside the menu (the `c` button still toggles the whole
  #     menu shut). Left as-is; flip it in jellyfinShimSettings if the trade
  #     looks right from the sofa.
  # `c` opens that menu — track selection and library browsing, i.e. the browse
  # UI the shim otherwise lacks. remote.nix puts it on a spare colour-wheel
  # button.
  xdg.configFile."jellyfin-mpv-shim/input.conf".text = mpvInputConf;
  xdg.configFile."jellyfin-mpv-shim/mpv.conf".text = mpvConfCommon;

  # ── The shim's own settings ─────────────────────────────────────────────────
  # Merged into the live conf.json rather than symlinked from the store, which
  # is what the rest of this file does. Three reasons, all from the shim's
  # source (conf.py):
  #   • Settings.load() calls save() whenever the file on disk has fewer keys
  #     than the schema — i.e. every time we declare a subset, which is always.
  #     2.10.0's save() opens the path "w", so against a store symlink that is a
  #     failed truncate of a read-only file on every start: logged, harmless,
  #     and permanent. Newer versions write-then-rename instead, which would
  #     replace the symlink with a real file and leave the config silently
  #     unmanaged until the next rebuild relinked it.
  #   • credentials are *not* in here. conf.json is settings only; the server
  #     URL and access token live beside it in users.json (clients.py, migrated
  #     from the older cred.json), so nothing secret is being written to the
  #     store either way.
  #   • it leaves the shim free to persist the things it owns — volume, shader
  #     profile, window geometry — instead of failing to.
  # Re-asserted on every activation, so a setting changed through the shim's own
  # menu is reverted at the next rebuild. That is the intended direction.
  # The shim reads conf.json once at startup: `systemctl --user restart
  # jellyfin-mpv-shim` to pick this up without waiting for the next login.
  home.activation.jellyfinMpvShimSettings =
    lib.hm.dag.entryAfter [ "writeBoundary" ] ''
      confdir="${config.xdg.configHome}/jellyfin-mpv-shim"
      conf="$confdir/conf.json"
      managed=${lib.escapeShellArg (builtins.toJSON jellyfinShimSettings)}
      jq=${pkgs.jq}/bin/jq

      run mkdir -p "$confdir"

      # An unreadable or absent file starts from {}: the shim fills in every
      # other key itself on first load, and a conf.json it can't parse is one it
      # is already ignoring, so there is nothing to preserve.
      existing='{}'
      if [ -s "$conf" ] && "$jq" -e . "$conf" >/dev/null 2>&1; then
        existing=$(cat "$conf")
      fi

      # Bail rather than write on a failed merge: an empty $merged getting past
      # the comparison below would truncate the file, taking the shim's own
      # state (volume, shader profile, window geometry) with it.
      if ! merged=$(printf '%s' "$existing" \
          | "$jq" -S --argjson managed "$managed" '. * $managed'); then
        warnEcho "jellyfin-mpv-shim: could not merge settings, leaving $conf alone"
      # Only touch the file when it would actually change — auto-upgrade.nix
      # runs this every 15 minutes.
      elif [ "$merged" != "$(printf '%s' "$existing" | "$jq" -S .)" ]; then
        tmp=$(mktemp)
        printf '%s\n' "$merged" > "$tmp"
        run install -m 644 "$tmp" "$conf"
        rm -f "$tmp"
      fi
    '';

  # ── What shows up on the Bigscreen home grid ────────────────────────────────
  # Until now this was whatever .desktop files the installed packages happened
  # to ship. Two levers, both declarative:
  #
  # 1. A launcher for the gamescope-wrapped Moonlight that apps.nix only
  #    described in a comment. gamescope is called by bare name on purpose:
  #    programs.gamescope with capSysNice installs a setcap wrapper, and the
  #    plain store path would run without the nice permissions it needs.
  #    60 Hz, not the 120 in that comment, because the native HDMI port is
  #    capped at HDMI 2.0 bandwidth until amdgpu lands FRL — see desktop.nix,
  #    where 4K60 is the mode that fits without chroma subsampling.
  xdg.desktopEntries.moonlight-hdr = {
    name = "Moonlight (HDR)";
    genericName = "Game Streaming";
    comment = "Stream games from a PC, nested in gamescope so HDR survives";
    exec = "gamescope --hdr-enabled -f --nested-refresh 60 -- ${pkgs.moonlight-qt}/bin/moonlight";
    icon = "com.moonlight_stream.Moonlight";
    terminal = false;
    categories = [ "Game" "AudioVideo" ];
  };

  # 2. Hide the tiles that are noise on a TV. This is Bigscreen's own filter,
  #    not a NoDisplay override: its app model reads ~/.config/applications-
  #    blacklistrc and drops any service whose desktop entry name is listed
  #    (applicationlistmodel.cpp, applicationsBlacklist). That keeps the effect
  #    to the 10-foot shell — everything here is still launchable from a normal
  #    Plasma session, which desktop.nix keeps available as a fallback.
  #
  #    Names are desktop file basenames without the extension, checked against
  #    the real listing on the box:
  #      ls /run/current-system/sw/share/applications
  #    An entry that isn't installed is simply ignored, so this is safe to
  #    over-specify — but everything below is actually present. Bigscreen
  #    already drops NoDisplay entries, Terminal=true entries and non-
  #    applications on its own, so the ~90 kcm_*, akonadi_* and daemon files in
  #    that directory need no help from us; what is left is the desktop apps
  #    Plasma 6 drags in, none of which are drivable from a remote.
  #
  #    kdeconnect is here because programs.kdeconnect.enable exists only to
  #    satisfy a QML import in Bigscreen's homescreen (desktop.nix) — nobody is
  #    pairing a phone to send SMS from the sofa. mpv/umpv are hidden because a
  #    tile that opens an idle player with no file is useless; mpv is still the
  #    handler for video files via xdg.mimeApps above. The stock Moonlight tile
  #    goes because the gamescope/HDR entry above replaces it — drop that line
  #    to get both back.
  #
  #    Deliberately left visible: firefox, VacuumTube, plasma-bigscreen-swap-
  #    session (the escape hatch to a normal desktop session), and Bigscreen's
  #    own org.kde.plasma.keyboard / uvcviewer.
  xdg.configFile."applications-blacklistrc".text = ''
    [Applications]
    blacklist=${lib.concatStringsSep "," [
      # Bolted on for a QML import, not for use.
      "org.kde.kdeconnect.app"
      "org.kde.kdeconnect.sms"
      "org.kde.kdeconnect.nonplasma"
      # Players/viewers with no job on the home grid.
      "mpv"
      "umpv"
      "org.kde.elisa"
      "org.kde.gwenview"
      "org.kde.okular"
      "com.moonlight_stream.Moonlight"
      # Desktop furniture Plasma 6 ships.
      "org.kde.dolphin"
      "org.kde.konsole"
      "org.kde.kate"
      "org.kde.kwrite"
      "org.kde.ark"
      "org.kde.spectacle"
      "org.kde.discover"
      "org.kde.khelpcenter"
      "org.kde.kmenuedit"
      "org.kde.knetattach"
      "org.kde.kwalletmanager"
      "org.kde.kcolorschemeeditor"
      "org.kde.kfontview"
      "org.kde.plasma.emojier"
      "org.kde.plasma-interactiveconsole"
      "org.kde.plasmawindowed"
      "org.kde.qrca"
      "nixos-manual"
      # Settings front-ends. Bigscreen has its own, on the remote's Settings
      # button (kcm_mediacenter_* are the pages it shows).
      "systemsettings"
      "kdesystemsettings"
      "org.kde.kinfocenter"
      "org.kde.plasma-systemmonitor"
      "breezestyleconfig"
      "kwincompositing"
    ]}
  '';

  # ── Default applications ────────────────────────────────────────────────────
  # So a video opened from anywhere lands in mpv rather than whatever Plasma
  # picked first. Same read-only-symlink trade as kxkbrc below: the File
  # Associations KCM can no longer save, which costs nothing on a box with no
  # keyboard and makes the association survive a reinstall.
  xdg.mimeApps = {
    enable = true;
    defaultApplications =
      let
        mpv = [ "mpv.desktop" ];
        types = [
          "video/mp4" "video/x-matroska" "video/webm" "video/mpeg"
          "video/quicktime" "video/x-msvideo" "video/x-flv" "video/avi"
          "audio/mpeg" "audio/flac" "audio/x-vorbis+ogg" "audio/mp4"
          "audio/x-wav" "audio/opus"
        ];
      in
      lib.genAttrs types (_: mpv);
  };

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
  # This has to be an edit of the live file rather than an xdg.configFile
  # symlink, because kglobalacceld rewrites kglobalshortcutsrc itself — every
  # component that registers an action persists it there — and a read-only store
  # symlink would break that. plasma-manager is exactly that, declared: it reads
  # the existing file at activation, merges in the keys below, and writes it back
  # (modules/shortcuts.nix -> write_config.py), which is what the hand-rolled
  # kwriteconfig6 loop that used to live here was doing by hand. `[ ]` writes the
  # key as `none`, which is what kglobalaccel parses as "no shortcut" (the old
  # loop wrote `none,none,<action>`; the only difference is that the compiled-in
  # default is now recorded as absent rather than as the literal string "none").
  #
  # The daemon caches shortcuts in memory, so this lands at the next login (or
  # after `systemctl --user restart plasma-kglobalaccel`).
  programs.plasma = {
    enable = true;

    shortcuts = {
      mediacontrol = {
        playpausemedia = [ ];
        stopmedia = [ ];
        seekforwardmedia = [ ];
        seekbackwardmedia = [ ];
      };

      # ── Pin what the remote points at ────────────────────────────────────────
      # remote.nix records buttons against these two, but they were only ever
      # Plasma's compiled-in defaults — nothing stopped an update from moving
      # them and silently killing a button. Writing them makes the remote's map
      # and the shell's map the same declaration.
      #
      # kwin's "Window Close" is what the CLOSE APP button uses to drop back to
      # the homescreen (Alt+F4, chosen in remote.nix because Bigscreen's own
      # Tasks-overview key is broken upstream).
      kwin."Window Close" = "Alt+F4";

      # Bigscreen's home overlay — the HOME button (Meta+O), registered in
      # plasma-bigscreen's containments/homescreen/plugin/shortcuts.cpp as an
      # action named "Toggle Bigscreen Home Overlay". The component is
      # plasmashell, not plasma-bigscreen: the containment plugin creates its
      # QActions without a KActionCollection, so KGlobalAccel falls back to the
      # host application's name. Confirmed against the running box, where
      # kglobalshortcutsrc carries it as
      #   [plasmashell]
      #   Toggle Bigscreen Home Overlay=Meta+O,Meta+O,Toggle Bigscreen Home Overlay
      # We write only the first of those three fields (`Meta+O,,`), which is the
      # one kglobalaccel grabs; plasmashell fills the default and the friendly
      # name back in when it re-registers the action at the next login.
      plasmashell."Toggle Bigscreen Home Overlay" = "Meta+O";
    };
  };
}
