{
  config,
  pkgs,
  lib,
  ...
}:

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
    #
    # These four govern *standalone* mpv only. jellyfin-mpv-shim force-binds the
    # arrows to its own handlers (kb_menu_left/right/up/down in conf.json), which
    # drive the OSD menu while it is open and otherwise seek by the shim's own
    # seek_left/seek_right/seek_up/seek_down — conf.json values that default to
    # ∓5s and ±60s. A force-mode script binding outranks input.conf, so under the
    # shim it is those that apply, not the numbers below. They are pinned to the
    # same steps in jellyfinShimSettings so the two agree; retune both together.
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

    # Back. Stop playback rather than dropping out of fullscreen. This line is
    # what standalone mpv uses; under jellyfin-mpv-shim the equivalent comes
    # from conf.json's kb_stop, which the shim binds over the top of this one.
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
  # Carries two unrelated jobs: the key-repeat tuning the remote needs, and the
  # player half of the HDR work desktop.nix does at the compositor level.
  mpvConfCommon = ''
    # Managed by home/htpc.nix — see hosts/htpc/remote.nix for the remote map.

    # ── Key repeat while a button is held ─────────────────────────────────────
    # mpv runs its own auto-repeat rather than following the compositor's: the
    # Wayland backend adopts wl_keyboard's repeat_info only when
    # --native-keyrepeat is set, and that defaults to no. So these two options —
    # not Plasma's keyboard settings — are what the remote's held buttons obey.
    #
    # mpv's defaults are tuned for a keyboard and are wrong for an IR remote:
    #
    #   input-ar-delay=200   A deliberate thumb press outlasts 200ms easily, and
    #                        the Flirc keeps the key held for as long as IR
    #                        repeat frames keep arriving — one press, two seeks.
    #   input-ar-rate=40     Forty repeats a second against a 60s seek is forty
    #                        minutes of video per second held. Uncontrollable.
    #
    # 800ms is longer than any single press (the dongle drops the key well
    # before then), so a tap is always exactly one seek. Hold past it and
    # repeats start at 2/s: two minutes of video per second on REWIND/FORWARD, a
    # minute on the Skip keys. Raise the delay if a press still double-fires;
    # raise the rate to scrub faster.
    #
    # The d-pad is deliberately absent from that list — it does not repeat at
    # all under the shim, and no value here will change that. Those arrows are
    # script bindings, and while mpv does emit repeat events for them
    # (script-binding is allow_auto_repeat), python-mpv discards them: its
    # on_key_press takes a `repetition` flag, defaulting to False, that the shim
    # never sets, so only the initial down event reaches the handler. Freeing
    # the arrows by clearing kb_menu_* in conf.json would restore native repeat
    # — at the cost of leaving the shim's OSD menu with no way to navigate it.
    input-ar-delay=800
    input-ar-rate=2

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

    # ── BACK stops playback instead of un-fullscreening the player ────────────
    # Upstream binds ESC to kb_menu_esc, whose no-menu branch runs
    #   self._player.command("set", "fullscreen", "no")
    #   self.fullscreen_disable = True
    # and that flag is sticky: every later item checks `if settings.fullscreen
    # and not self.fullscreen_disable` before going fullscreen, and only
    # toggle_fullscreen clears it — which lives on kb_fullscreen ("f"), a key
    # this remote does not send. So one press of BACK during playback left the
    # player windowed for the rest of the session with no way back from the
    # sofa. The `ESC stop` line in input.conf never got a chance to prevent it;
    # a script binding beats input.conf.
    #
    # Pointing kb_stop at ESC hands the button to handle_stop -> stop_and_close,
    # which is the same teardown the STOP button already uses and a cleaner one
    # than input.conf's raw `stop` — it releases the cast session rather than
    # leaving the shim to notice after the fact.
    #
    # kb_menu_esc has to move off "esc" for that to take: player.py registers
    # kb_stop first and kb_menu_esc second, so a shared key would go to the
    # menu. F24 is a real mpv key name (`mpv --input-keylist`) that nothing here
    # can produce — it must be *some* valid name, since the registration is
    # unguarded and a null would fail conf.json's schema outright. The cost is
    # "back one level" inside the OSD menu; `c` still toggles the whole menu
    # shut from any depth, which is the way out.
    kb_stop = "esc";
    kb_menu_esc = "F24";

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
  imports = [
    ./linux.nix
    ./htpc/plasma.nix
  ];

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
  # config directory, alongside conf.json. It only ensures mpv.conf *exists* (an
  # existing symlink satisfies that) and passes config-dir to mpv, which is what
  # actually loads it.
  #
  # The shim also layers its own keybinds on top (kb_* in conf.json), and those
  # *win* over input.conf — they are registered as script bindings after the
  # config is read. Two consequences worth knowing from the couch:
  #   • the D-pad seek steps come from conf.json's seek_* , not from the `seek`
  #     lines above; they are pinned to match in jellyfinShimSettings.
  #   • ESC likewise never reaches the `ESC stop` line above. Upstream binds it
  #     to kb_menu_esc, which un-fullscreens the player for the rest of the
  #     session; jellyfinShimSettings moves that binding aside and points
  #     kb_stop at ESC instead, so BACK stops playback the way the line above
  #     always meant it to. The reasoning is at those two settings.
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
  home.activation.jellyfinMpvShimSettings = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
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
  # The gamescope-wrapped Moonlight launcher enables HDR on the TV. Moonlight
  #    renders through SDL without Wayland colour management, so its window is SDR
  #    whatever the stream carries; gamescope is a nested compositor that does
  #    speak the protocol and hands KWin a correctly tagged HDR surface on
  #    Moonlight's behalf. (mpv needs none of this — vo=gpu-next talks colour
  #    management itself, which is what target-colorspace-hint above turns on.)
  #
  #    gamescope is called by bare name on purpose: programs.gamescope with
  #    capSysNice installs a setcap wrapper, and the plain store path would run
  #    without the nice permissions it needs.
  #
  #    -W/-H are not optional. gamescope's nested Wayland backend defaults
  #    g_nOutputHeight to 720 when -H is absent and then derives the width as
  #    720*16/9 (Backends/WaylandBackend.cpp, CWaylandBackend::Init), and the
  #    game surface inherits the output size when -w/-h are unset (main.cpp) —
  #    so without these the stream ran at 1280x720 and -f simply stretched it
  #    over the whole 4K panel. Setting the output size is enough; -w/-h would
  #    be redundant. gamescope rejects -W without -H, so they travel together.
  #
  #    3840x2160 at 60 Hz, not the 120 in apps.nix's comment, because the
  #    native HDMI port is capped at HDMI 2.0 bandwidth until amdgpu lands FRL
  #    — see desktop.nix, where 4K60 is the mode that fits without chroma
  #    subsampling. If the TV or its mode ever changes, this is the line.
  #
  #    Named plainly "Moonlight" because it is the only one on the grid: the
  #    stock com.moonlight_stream.Moonlight tile is blacklisted below, so there
  #    is nothing to disambiguate it from. The attribute name stays
  #    moonlight-hdr — that is the desktop *id*, invisible on the tile, and
  #    keeping it distinct is what stops it colliding with the stock entry.
  #
  #    The icon is the theme name "moonlight", which is what the stock entry
  #    uses and what nixpkgs actually installs
  #    (share/icons/hicolor/scalable/apps/moonlight.svg). It is *not* named
  #    after the desktop file; assuming so is what left this tile blank.
  xdg.desktopEntries.moonlight-hdr = {
    name = "Moonlight";
    genericName = "Game Streaming";
    comment = "Stream games from a PC, nested in gamescope so HDR survives";
    exec = "gamescope --hdr-enabled -f -W 3840 -H 2160 --nested-refresh 60 -- ${pkgs.moonlight-qt}/bin/moonlight";
    icon = "moonlight";
    terminal = false;
    categories = [
      "Game"
      "AudioVideo"
    ];
  };

  xdg.desktopEntries.music-assistant-party = {
    name = "Music Assistant Party";
    comment = "Open the party queue and guest QR code";
    exec = ''${pkgs.firefox}/bin/firefox --kiosk --new-window "https://musicassistant.nasa.jmalexan.com/#/party?frameless"'';
    icon = toString (
      pkgs.fetchurl {
        name = "music-assistant.svg";
        url = "https://raw.githubusercontent.com/music-assistant/frontend/14c6d472d1ed9924b3fd0e75b1642c8d4e54f504/public/favicon.svg";
        hash = "sha256-ML5MBb4Aau0BAJ2zakC2Bj9PAiTdej64Z67ITcdPP5Y=";
      }
    );
    terminal = false;
    categories = [
      "AudioVideo"
      "Audio"
    ];
  };

  # Bigscreen uses desktop entry names without the .desktop suffix.
  xdg.configFile."applications-allowlistrc".text = ''
    [Applications]
    allowlist=${
      lib.concatStringsSep "," [
        "VacuumTube"
        "moonlight-hdr"
        "music-assistant-party"
        "org.kde.plasma.keyboard"
      ]
    }
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
          "video/mp4"
          "video/x-matroska"
          "video/webm"
          "video/mpeg"
          "video/quicktime"
          "video/x-msvideo"
          "video/x-flv"
          "video/avi"
          "audio/mpeg"
          "audio/flac"
          "audio/x-vorbis+ogg"
          "audio/mp4"
          "audio/x-wav"
          "audio/opus"
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

}
