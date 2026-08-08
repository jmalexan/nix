# KDE Plasma 6 (Wayland) with the Plasma Bigscreen 10-foot shell as the default
# session, autologin straight to the couch UI.
#
# Bigscreen was re-ported to Qt6/Plasma 6 and ships as kdePackages.plasma-bigscreen
# 6.7.x — but ONLY on nixos-unstable (stable 26.05 is still Plasma 6.6). That's why
# this host is built from nixpkgs-unstable in flake.nix. The base Plasma 6 desktop
# is still enabled underneath, so you can drop to a normal "Plasma (Wayland)"
# session from SDDM if Bigscreen ever misbehaves.
{
  pkgs,
  ...
}:

let
  # ── Idle timeouts ───────────────────────────────────────────────────────────
  # Screen off first, sleep a while later. Both clocks only advance while the
  # session is actually idle — see the inhibitor notes further down.
  screenOffSeconds = 15 * 60;
  suspendSeconds = 30 * 60;

  # Backstop for "only sleep when nothing is playing". kde-inhibit holds an
  # org.freedesktop.PowerManagement.Inhibit for exactly as long as its child
  # process runs, so the inhibition is re-taken in slices for as long as audio
  # keeps flowing, and lapses on its own within one slice of the audio stopping
  # (including if this service is killed — nothing can get stuck held).
  audioHoldSeconds = 60;
  audioPollSeconds = 30;

  media-idle-inhibit = pkgs.writeShellApplication {
    name = "media-idle-inhibit";
    runtimeInputs = [
      pkgs.pulseaudio
      pkgs.kdePackages.kde-cli-tools
      pkgs.coreutils
    ];
    text = ''
      # An *uncorked* sink input is the honest signal for "something is playing
      # right now": a paused mpv or a finished stream corks itself, and an idle
      # player has no sink input at all. LC_ALL=C because pactl localises the
      # yes/no it prints here.
      audio_playing() {
        LC_ALL=C pactl list sink-inputs 2>/dev/null | grep -q '^[[:space:]]*Corked: no$'
      }

      while true; do
        if audio_playing; then
          kde-inhibit --power sleep ${toString audioHoldSeconds}
        else
          sleep ${toString audioPollSeconds}
        fi
      done
    '';
  };
in
{
  services.displayManager.sddm = {
    enable = true;
    wayland.enable = true;
  };
  services.desktopManager.plasma6.enable = true;

  # Register the Bigscreen Wayland session and make it the default.
  services.displayManager.sessionPackages = [ pkgs.kdePackages.plasma-bigscreen ];

  # plasma-bigscreen's session launcher sources `plasma-bigscreen-common-env` by
  # bare name, so the package's bin/ must be on the session PATH. Registering it
  # only as a sessionPackage (above) doesn't do that — it must also be in
  # environment.systemPackages, otherwise the session dies to a black screen.
  environment.systemPackages = [ pkgs.kdePackages.plasma-bigscreen ];

  # Bigscreen's homescreen imports QML modules that its nixpkgs package doesn't
  # pull in itself. Each missing `module "..." is not installed` maps to a package:
  #   org.kde.kdeconnect -> kdeconnect-kde (enabled below)
  programs.kdeconnect.enable = true;

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

  # ── Screen locking ───────────────────────────────────────────────────────────
  # Autologin gets us to the couch UI without a password, but kscreenlocker then
  # locks the session on its own. Two defaults are in play, both `true`, both
  # wrong for a TV driven by a remote with no keyboard:
  #   • LockOnResume — ksldapp.cpp locks on logind's PrepareForSleep, i.e. at
  #     *suspend* time, which is why the password prompt is sitting there waiting
  #     when the box wakes back up.
  #   • Autolock — locks after Timeout (default 5) idle minutes, which this host
  #     reaches long before the idle timeouts below ever come into play.
  #
  # Set as a system-wide KDE default rather than via home-manager: the plasma6
  # module already puts /etc/xdg on XDG_CONFIG_DIRS, so KConfig reads this
  # without anyone having to own ~/.config/kscreenlockerrc — a file Plasma
  # rewrites at runtime. The `[$i]` kiosk markers make just these two keys
  # immutable, so an existing user value can't shadow them while the rest of the
  # group (greeter theme, wallpaper) stays editable in System Settings. Those two
  # checkboxes will show as greyed out there, which is intended, not a bug.
  #
  # No real change in posture: autologin already means physical access is session
  # access, and this box has no keyboard attached.
  environment.etc."xdg/kscreenlockerrc".text = ''
    [Daemon]
    Autolock[$i]=false
    LockOnResume[$i]=false
  '';

  # ── Idle: screen off, then sleep ─────────────────────────────────────────────
  # This box does now suspend on idle. What kept it awake was never power, it was
  # *wake-up*: a Bluetooth controller cannot wake a suspended PC. The Flirc USB
  # IR receiver (remote.nix) can — it's a USB HID device, and with sleep
  # detection enabled it emits a USB wakeup event instead of a keystroke — so the
  # Skip 1s is what brings the box back, and any button on it will do.
  #
  # Two BIOS settings on the UM760 are load-bearing here. Without them the box
  # sleeps and does not come back:
  #   • enable "USB Wake Support"
  #   • disable "ErP Ready"   (ErP cuts USB standby power, killing wake)
  # Powering on the Xbox controller still won't wake it — reach for the remote.
  # (The Xbox Wireless Dongle would also work; see controller.nix.)
  #
  # The idle timer belongs to PowerDevil, not logind. logind's IdleAction fires
  # off the session's idle *hint*, which Plasma never sets — the session would
  # read as busy forever — so leaving it "ignore" keeps exactly one idle clock in
  # play rather than one working timer and one dead one.
  services.logind.settings.Login.IdleAction = "ignore";

  # ── Not while something is playing ───────────────────────────────────────────
  # PowerDevil doesn't run its own idle clock — it asks KWin, over
  # ext-idle-notify-v1. KWin *pauses* those timers outright while any visible
  # window holds a Wayland idle inhibitor (IdleDetector::setInhibited stops the
  # timer rather than letting it expire), so an inhibitor suppresses the screen
  # blanking and the suspend together. Every player here takes one while it is
  # genuinely playing:
  #   • mpv, and so jellyfin-mpv-shim — zwp_idle_inhibitor_v1, driven by
  #     stop-screensaver. Dropped on pause, so a film left paused does
  #     eventually sleep; that's the intended reading of "nothing is playing".
  #   • VacuumTube (Electron) and Firefox — the same protocol, for video.
  #   • moonlight-qt — SDL takes one for the duration of a stream.
  # Note what is NOT activity: gamepad input. KWin's idle detection comes from
  # libinput, which doesn't handle joysticks at all, so a controller alone never
  # resets the clock — during a stream it's moonlight's inhibitor doing the work,
  # not your thumbsticks.
  #
  # media-idle-inhibit is the backstop for anything that forgets to inhibit
  # (an app under gamescope, say, whose nested compositor may not forward the
  # protocol): while any audio stream is uncorked it holds a power-management
  # inhibition, which blocks the suspend. It deliberately does not block the
  # screen blanking — video apps keep the screen up themselves, and audio-only
  # playback has no reason to hold a TV panel on.
  systemd.user.services.media-idle-inhibit = {
    description = "Inhibit auto-suspend while audio is playing";
    after = [ "graphical-session.target" ];
    partOf = [ "graphical-session.target" ];
    wantedBy = [ "graphical-session.target" ];
    serviceConfig = {
      ExecStart = "${media-idle-inhibit}/bin/media-idle-inhibit";
      Restart = "always";
      RestartSec = 5;
    };
  };

  # The timeouts themselves. Same /etc/xdg + kiosk-marker trick as
  # kscreenlockerrc above, and for the same reason: these have to win over a
  # ~/.config/powerdevilrc that Plasma rewrites at runtime. The Power Management
  # page in System Settings will show them greyed out — change them here.
  #
  # Shape and units are PowerDevil 6's (PowerDevilProfileSettings.kcfg): nested
  # <profile><group> headers, plain seconds, and AutoSuspendAction is a
  # PowerButtonAction enum where 1 = Sleep and 0 = do nothing. "AC" is the
  # profile a machine with no battery always runs. Dimming is off because
  # PowerDevil would try it over DDC/CI on the TV; on a 10-foot UI that reads as
  # a fault, not a warning.
  environment.etc."xdg/powerdevilrc".text = ''
    [AC][Display]
    DimDisplayWhenIdle[$i]=false
    TurnOffDisplayWhenIdle[$i]=true
    TurnOffDisplayIdleTimeoutSec[$i]=${toString screenOffSeconds}
    LockBeforeTurnOffDisplay[$i]=false

    [AC][SuspendAndShutdown]
    AutoSuspendAction[$i]=1
    AutoSuspendIdleTimeoutSec[$i]=${toString suspendSeconds}
    SleepMode[$i]=1
  '';
  # If resume ever misbehaves on this hardware, AutoSuspendAction=0 turns the
  # sleep half off and leaves the screen blanking in place.
}
