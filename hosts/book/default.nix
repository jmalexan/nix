{
  pkgs,
  agenix,
  vars,
  ...
}:

{
  imports = [
    ../../modules/dev-environment.nix
  ];

  # ── Platform ──────────────────────────────────────────────────────────────

  nixpkgs.hostPlatform = "aarch64-darwin";

  # ── Identity ──────────────────────────────────────────────────────────────

  system.primaryUser = vars.user.name;

  users.users.${vars.user.name} = {
    # Needed so home-manager can infer the user's home directory
    home = "/Users/${vars.user.name}";
    shell = pkgs.fish;
  };

  networking.hostName = "Book";
  networking.computerName = "Book";

  # ── Locale & Time ─────────────────────────────────────────────────────────

  time.timeZone = vars.timeZone;

  # ── Packages ──────────────────────────────────────────────────────────────

  environment.systemPackages = [
    # Secrets management (CLI only — for managing NAS secrets from this machine)
    agenix.packages.${pkgs.stdenv.hostPlatform.system}.default

    # Force an early update check (same name/behaviour as on the NixOS hosts).
    # darwin-rebuild picks the config attr from the hostname ("Book").
    (pkgs.writeShellScriptBin "update-now" ''
      echo "→ Pulling latest config from GitHub and switching…"
      exec sudo darwin-rebuild switch --refresh --flake ${vars.repository} "$@"
    '')
  ];

  # ── Shell ─────────────────────────────────────────────────────────────────

  environment.shells = [ pkgs.fish ];

  # ── Nix Settings ──────────────────────────────────────────────────────────

  # Automatic garbage collection (launchd interval format, not systemd dates)
  nix.gc = {
    automatic = true;
    interval = {
      Weekday = 0;
      Hour = 0;
      Minute = 0;
    }; # Sundays at midnight
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
      "rust"
      "wasm-pack"
      "yt-dlp"
    ];

    casks = [
      "betterdisplay" # Better Display Pro (enter license to unlock Pro features)
      "blender"
      "daisydisk"
      "claude"
      "cleanshot" # CleanShot X
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
      "Amphetamine" = 937984704;
      "Bitwarden" = 1352778147;
      "Field Kit" = 1612653346;
      "Flighty" = 1358823008;
      "iA Writer" = 775737590;
      "Things 3" = 904280696;
      "Xcode" = 497799835;
    };
  };

  # ── Auto-upgrade ──────────────────────────────────────────────────────────
  #
  # Deliberately none. Unlike the NixOS hosts deployed by GitHub Actions, this
  # machine is updated by hand with `update-now` (defined above), because on
  # macOS even a no-op `darwin-rebuild switch` causes minor UI disruptions.

  # ── System ────────────────────────────────────────────────────────────────

  # Used for backwards compatibility — set at first activation, do NOT change.
  system.stateVersion = 5;
}
