# Skip 1s universal remote + Flirc USB IR receiver.
#
# ── How the pieces fit ───────────────────────────────────────────────────────
# The Flirc USB is not an IR device as far as Linux is concerned: it decodes IR
# in its own firmware and presents itself as a plain USB HID **keyboard**. The
# IR-code → keystroke table lives in the dongle's flash, so there is nothing to
# configure at the kernel level — no LIRC, no ir-keytable, no evdev remapping.
# That also means the mapping survives reinstalls and follows the dongle, which
# is why it can't be expressed declaratively here; see the wizard below.
#
# The Skip 1s is IR-only (no Bluetooth). It has three activities (A/B/C), and
# each activity maps its buttons to a *device profile*. The SkipApp only runs on
# macOS and Windows — Linux support is still "planned" — so the remote itself is
# programmed from Book, not from here.
#
# Two-stage setup, and both stages are needed:
#
#   1. SkipApp (on Book): add the "Flirc — Kodi" device to an activity. This is
#      what decides which IR codes each Skip button transmits. Assign *every*
#      button you care about to some distinct Kodi function, even a nonsense one
#      — the function itself doesn't matter, it only has to make the button emit
#      a code the Flirc can recognise. Sync to the remote over USB-C.
#
#   2. flirc_util (here, on the HTPC): re-point those codes at the keys this
#      host actually wants. Recorded pairings take precedence over the dongle's
#      built-in Kodi profile, so anything left unrecorded keeps its Kodi
#      default. Run `flirc-skip-setup` (packaged below) to do the whole pass.
#
# The two apps do not share state: changes made in one are invisible to the
# other. That's expected, not a bug.
{ config, lib, pkgs, ... }:

let
  # ── The mapping ─────────────────────────────────────────────────────────────
  # Chosen against what Bigscreen and the media apps actually listen for, rather
  # than what a Kodi remote traditionally sends. The Bigscreen side is not
  # guesswork — these are the bindings plasma-bigscreen 6.7 registers in
  # containments/homescreen/plugin/shortcuts.cpp and the back handler in
  # components/bigscreenplugin/backhandler.cpp:
  #
  #   Home overlay ...... Meta+O        (apps, search, settings, running apps)
  #   Home screen ....... XF86HomePage  ← NOT reachable, see note below
  #   Tasks overview .... Menu          ← BROKEN UPSTREAM, see note below
  #   Settings overlay .. Qt::Key_Settings
  #   Back .............. Escape or XF86Back
  #   Navigate/select ... arrows + Return
  #
  # Note on Home: `flirc_util record` has no name for XF86HomePage — its media
  # keys stop at wake/eject/vol/mute/play-pause/stop/rewind/fast_forward/
  # next_track/prev_track — and `record_api` only reaches the HID *keyboard*
  # usage page, not the consumer page where AC Home lives. So the plain home
  # screen key can't be produced. Meta+O is used instead, and is the better
  # target anyway: the overlay is a superset (it can jump to the homescreen,
  # switch between running apps, search, and open settings).
  #
  # `record_api <modifier> <hid-usage>`: modifier is the HID bitmask
  # (1=LCtrl 2=LShift 4=LAlt 8=LMeta, ×16 for the right-hand side), and the
  # second argument is a HID keyboard usage ID — 4='a' … 18='o', 101=Application
  # (Menu), 104-115=F13-F24.
  #
  # F13-F17 are deliberate: nothing else on the system claims them, so they are
  # safe to route to app-specific actions via mpv's input.conf (home/htpc.nix).
  buttons = [
    { desc = "D-pad UP";       args = "record up";           note = "menu up / mpv +60s"; }
    { desc = "D-pad DOWN";     args = "record down";         note = "menu down / mpv -60s"; }
    { desc = "D-pad LEFT";     args = "record left";         note = "menu left / mpv -10s"; }
    { desc = "D-pad RIGHT";    args = "record right";        note = "menu right / mpv +10s"; }
    # Must be HID 40 = Keyboard Return, NOT flirc's `record enter`, which sends
    # keypad Enter (HID 88). Qt treats those as two different keys —
    # Qt::Key_Return vs Qt::Key_Enter — and every activation handler in
    # plasma-bigscreen uses `Keys.onReturnPressed` or tests Qt.Key_Return
    # (components/bigscreenplugin/qml/AbstractDelegate.qml, which the homescreen
    # app tiles derive from). Nothing in the whole shell handles onEnterPressed,
    # so keypad Enter silently does nothing on the homescreen while still working
    # in Chromium-based apps like VacuumTube, which treat both as "Enter".
    { desc = "OK / SELECT";    args = "record_api 0 40";     note = "Return - activate / mpv pause"; }
    { desc = "BACK";           args = "record escape";       note = "Bigscreen back, mpv stop"; }
    { desc = "HOME";           args = "record_api 8 18";     note = "Meta+O - Bigscreen home overlay"; }
    # NOT the Menu key (HID 101). Bigscreen 6.7.3 registers Qt::Key_Menu with
    # KGlobalAccel for its "Tasks overview" and emits toggleTasksOverlay(), but
    # no QML is connected to that signal — its three siblings (toggleHomeScreen,
    # toggleHomeOverlay, toggleSettingsOverlay) all have Connections handlers,
    # that one has none. So the key does nothing, and because kglobalaccel still
    # *grabs* it, it never reaches the focused app either. Not fixable from here.
    # The function itself is alive via the home overlay: Meta+O → "Tasks".
    #
    # Alt+F4 is a far better use of the button — Plasma's default Close Window,
    # i.e. "quit this app and drop me back on the homescreen".
    { desc = "CLOSE APP";      args = "record_api 4 61";     note = "Alt+F4 - close app, back to homescreen"; }
    { desc = "PLAY / PAUSE";   args = "record play/pause";   note = "mpv pause toggle"; }
    { desc = "STOP";           args = "record stop";         note = "mpv stop"; }
    { desc = "REWIND";         args = "record rewind";       note = "mpv -60s"; }
    { desc = "FAST FORWARD";   args = "record fast_forward"; note = "mpv +60s"; }
    { desc = "SKIP BACK";      args = "record_api 0 104";    note = "F13 - mpv -30s"; }
    { desc = "SKIP FORWARD";   args = "record_api 0 105";    note = "F14 - mpv +30s"; }
    { desc = "VOLUME UP";      args = "record vol_up";       note = "Plasma volume"; }
    { desc = "VOLUME DOWN";    args = "record vol_down";     note = "Plasma volume"; }
    { desc = "MUTE";           args = "record mute";         note = "Plasma mute"; }
    { desc = "INFO / GUIDE";   args = "record_api 0 106";    note = "F15 - mpv show-progress"; }
    { desc = "SUBTITLE";       args = "record_api 0 107";    note = "F16 - mpv cycle sub"; }
    { desc = "AUDIO TRACK";    args = "record_api 0 108";    note = "F17 - mpv cycle audio"; }
    { desc = "spare colour-wheel button, player MENU";
      args = "record c";       note = "jellyfin-mpv-shim menu; captions in VacuumTube"; }
    # No separate back key needed for VacuumTube: its YouTube UI takes Escape,
    # same as Bigscreen, so the one BACK button covers both.
    { desc = "POWER (see the caveat above)";
      args = "record suspend"; note = "HID System Sleep - logind suspends"; }
  ];

  # One tab-separated row per button, consumed by the wizard on fd 3.
  table = lib.concatMapStringsSep "\n" (b: "${b.desc}\t${b.args}\t${b.note}") buttons;

  flirc-skip-setup = pkgs.writeShellApplication {
    name = "flirc-skip-setup";
    runtimeInputs = [ pkgs.flirc pkgs.coreutils ];
    text = ''
      # Walk every Skip 1s button and pair it with the key this host wants.
      # Re-runnable: recording a button again just overwrites its pairing.

      table=$(cat <<'TABLE'
      ${table}
      TABLE
      )

      if [ "''${1-}" = "--list" ]; then
        printf '%s\n' "$table"
        exit 0
      fi

      cat <<'INTRO'
      ── Flirc USB / Skip 1s pairing ─────────────────────────────────────────

        First, on Book: SkipApp -> your HTPC activity -> add the "Flirc - Kodi"
        device, give every button you want here some distinct function, and
        sync the remote over USB-C.

        Then point the remote at the dongle. At each prompt press ENTER, then
        the button on the remote. Type "s" to skip one, Ctrl-C to stop.

        POWER caveat: in a universal-remote activity the power button usually
        already drives the TV/AVR. If so skip it here and put the Flirc
        suspend on a spare button, or add it to the power-off macro instead.
      INTRO

      echo
      echo "Looking for a Flirc USB..."
      if ! timeout 15 flirc_util wait; then
        echo
        echo "No Flirc USB found - plug it in and re-run." >&2
        exit 1
      fi
      flirc_util version || true

      # Sleep detection: while the host is asleep the dongle sends a USB wakeup
      # event instead of the recorded keystroke, which is what lets the remote
      # wake the box (BIOS also needs USB wake on / ErP off - see below).
      echo
      echo "Enabling sleep detection (needed for wake-from-suspend)..."
      flirc_util sleep_detect enable || echo "  (could not enable - continuing)"

      recorded=0
      skipped=0
      # The table is on fd 3 so that the prompts below can still read stdin.
      while IFS=$'\t' read -r desc args note <&3; do
        [ -n "$desc" ] || continue
        echo
        echo "── $desc"
        echo "   → $note"
        printf '   [ENTER] record, [s] skip: '
        read -r answer || answer=s
        case "$answer" in
          s | S | skip)
            echo "   skipped"
            skipped=$((skipped + 1))
            continue
            ;;
        esac
        echo "   press the button on the remote now..."
        # shellcheck disable=SC2086
        if flirc_util $args; then
          recorded=$((recorded + 1))
        else
          echo "   !! not recorded - re-run the wizard for this button later"
          skipped=$((skipped + 1))
        fi
      done 3<<TABLE
      $table
      TABLE

      echo
      echo "Done: $recorded recorded, $skipped skipped."
      echo

      # The dongle's flash is the only copy of this mapping, so take a backup.
      backup="''${FLIRC_BACKUP:-$HOME/flirc-skip1s.fcfg}"
      if flirc_util saveconfig "$backup"; then
        echo "Backed up the dongle's mapping to $backup"
        echo "Restore onto a replacement dongle with:"
        echo "  flirc_util loadconfig $backup"
      fi

      cat <<'OUTRO'

      Useful follow-ups:
        flirc_util settings     show every recorded pairing
        flirc_util device_log   watch what the dongle receives, live
        flirc_util profiles     built-in profiles (Kodi et al) on/off - leave ON
                                so unrecorded buttons still do something; turn
                                OFF if stray Kodi letter keys leak into
                                Bigscreen's search field
        flirc_util record_lp    add a hold-for-half-a-second second function to
                                a button you already recorded
      OUTRO
    '';
  };
in
{
  # ── Tooling ─────────────────────────────────────────────────────────────────
  # `flirc` ships both the Qt GUI (`Flirc`) and the CLI (`flirc_util`). It's
  # unfree, which is already allowed fleet-wide via modules/dev-environment.nix.
  # The package installs no .desktop file, so it won't show up as a Bigscreen
  # tile. The GUI needs a pointer; from the couch prefer the CLI or the wizard.
  environment.systemPackages = [ pkgs.flirc flirc-skip-setup ];

  # flirc_util talks to the dongle over raw USB/hidraw, which is root-only by
  # default. The package carries the udev rules that loosen this (vendor 20a0,
  # covering both the bootloader and application interfaces of gen1 and gen2).
  services.udev.packages = [ pkgs.flirc ];

  # ── Wake from suspend ───────────────────────────────────────────────────────
  # Unlike the Bluetooth Xbox controller (see controller.nix), the Flirc *can*
  # wake this box: it's a USB HID device, and with sleep detection enabled it
  # emits a USB wakeup event instead of a keystroke while the host is asleep.
  # This rule is the Linux half — same shape as the 045e rule in controller.nix.
  # `services.udev.extraRules` is a `lines` option, so the two merge cleanly.
  #
  # The BIOS half is identical to what the Xbox dongle needed on the UM760:
  #   • enable "USB Wake Support"
  #   • disable "ErP Ready"   (ErP cuts USB standby power, killing wake)
  services.udev.extraRules = ''
    ACTION=="add|change", SUBSYSTEM=="usb", DRIVERS=="usb", ATTRS{idVendor}=="20a0", ATTR{power/wakeup}="enabled"
  '';

  # Deliberately NOT flipping `services.logind.settings.Login.IdleAction` here.
  # desktop.nix keeps this box awake because a Bluetooth controller cannot wake
  # it; the Flirc removes that constraint, so idle-suspend is now a real option,
  # but that's a behaviour change rather than part of getting the remote working.
  # Suspending *on demand* from the remote already works with no host config:
  # a button recorded as `suspend` sends the HID System Sleep usage, which
  # logind handles via HandleSuspendKey (default: suspend).
}
