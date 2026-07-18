{ config, lib, pkgs, pkgs-unstable, claude-code-pkg, agenix, ... }:

{
  imports = [
    (import ../../modules/dev-environment.nix pkgs-unstable claude-code-pkg)
  ];

  # ── Platform ──────────────────────────────────────────────────────────────

  nixpkgs.hostPlatform = "aarch64-darwin";

  # ── Identity ──────────────────────────────────────────────────────────────

  system.primaryUser = "jmalexan";

  # Needed so home-manager can infer the user's home directory
  users.users.jmalexan.home = "/Users/jmalexan";

  networking.hostName = "Book";
  networking.computerName = "Book";

  # ── Locale & Time ─────────────────────────────────────────────────────────

  time.timeZone = "America/New_York";

  # ── Packages ──────────────────────────────────────────────────────────────

  environment.systemPackages = [
    # Secrets management (CLI only — for managing NAS secrets from this machine)
    agenix.packages.${pkgs.stdenv.hostPlatform.system}.default

    # Force an early update check (same name/behaviour as on the NixOS hosts).
    # darwin-rebuild picks the config attr from the hostname ("Book").
    (pkgs.writeShellScriptBin "update-now" ''
      echo "→ Pulling latest config from GitHub and switching…"
      exec sudo darwin-rebuild switch --refresh --flake github:jmalexan/nix "$@"
    '')
  ];

  # ── Shell ─────────────────────────────────────────────────────────────────

  users.users.jmalexan.shell = pkgs.fish;
  environment.shells = [ pkgs.fish ];

  # ── Nix Settings ──────────────────────────────────────────────────────────

  # Automatic garbage collection (launchd interval format, not systemd dates)
  nix.gc = {
    automatic = true;
    interval = { Weekday = 0; Hour = 0; Minute = 0; };  # Sundays at midnight
    options = "--delete-older-than 14d";
  };

  # ── macOS System Defaults ─────────────────────────────────────────────────

  system.defaults = {
    NSGlobalDomain = {
      AppleInterfaceStyleSwitchesAutomatically = true;
      AppleShowAllExtensions = true;
    };

    dock = {
      autohide = false;
      tilesize = 54;
      mru-spaces = false;
      wvous-br-corner = 14;
    };

    finder = {
      AppleShowAllFiles = true;
    };

    CustomUserPreferences = {
      NSGlobalDomain = {
        "com.apple.mouse.linear" = true;
        AppleMenuBarVisibleInFullscreen = 0;
        AppleMiniaturizeOnDoubleClick = 0;
        NSQuitAlwaysKeepsWindows = 1;
      };
      "com.apple.dock" = {
        wvous-br-modifier = 0;
      };
    };
  };

  # ── Homebrew ──────────────────────────────────────────────────────────────

  homebrew = {
    enable = true;

    onActivation = {
      cleanup = "zap";
      autoUpdate = false;
      upgrade = false;
    };

    brews = [
      "ffmpeg"
      "libpq"
      "yt-dlp"
    ];

    casks = [
      "betterdisplay"        # Better Display Pro (enter license to unlock Pro features)
      "blender"
      "daisydisk"
      "claude"
      "cleanshot"            # CleanShot X
      "discord"
      "element"
      "elgato-stream-deck"
      "font-fira-code"
      "font-symbols-only-nerd-font"
      "ghostty"
      "google-chrome"
      "godot"
      "little-snitch"
      "obs"
      "obsidian"
      "sf-symbols"
      "signal"
      "spotify"
      "tailscale-app"
      "thaw"
      "dot"
    ];

    masApps = {
      "Amphetamine"  = 937984704;
      "Bitwarden"    = 1352778147;
      "Field Kit"    = 1612653346;
      "Flighty"      = 1358823008;
      "iA Writer"    = 775737590;
      "Things 3"     = 904280696;
      "Xcode"        = 497799835;
    };
  };

  # ── Auto-upgrade ──────────────────────────────────────────────────────────
  #
  # nix-darwin has no `system.autoUpgrade`, so this is the pull-based equivalent
  # of the NixOS `modules/auto-upgrade.nix`: a root launchd daemon that rebuilds
  # this machine from the latest `main` on GitHub every 15 minutes.
  #
  # StartInterval fires every 900s while loaded; if the laptop was asleep,
  # launchd coalesces the missed intervals into a single run on wake — so it
  # catches up shortly after the machine comes back online. A failed build
  # leaves the running generation untouched. Manual deploys still work:
  #   darwin-rebuild switch --flake .

  launchd.daemons.auto-upgrade = {
    serviceConfig = {
      RunAtLoad = false;        # don't fire during an activation/switch
      StartInterval = 900;      # every 15 minutes
      StandardOutPath = "/var/log/darwin-auto-upgrade.log";
      StandardErrorPath = "/var/log/darwin-auto-upgrade.log";
    };
    script = ''
      export PATH=/run/current-system/sw/bin:/nix/var/nix/profiles/default/bin:$PATH
      # --refresh bypasses nix's 1h tarball cache so the 15-minute timer sees
      # new commits instead of replaying a stale fetch.
      exec darwin-rebuild switch --flake github:jmalexan/nix#Book --refresh
    '';
  };

  # ── System ────────────────────────────────────────────────────────────────

  # Used for backwards compatibility — set at first activation, do NOT change.
  system.stateVersion = 5;
}
