{ config, lib, pkgs, pkgs-unstable, agenix, ... }:

{
  # ── Platform ──────────────────────────────────────────────────────────────

  nixpkgs.hostPlatform = "aarch64-darwin";
  nixpkgs.config.allowUnfree = true;

  # ── Networking ────────────────────────────────────────────────────────────

  system.primaryUser = "jmalexan";

  # Needed so home-manager can infer the user's home directory
  users.users.jmalexan.home = "/Users/jmalexan";

  networking.hostName = "Book";
  networking.computerName = "Book";

  # ── Locale & Time ─────────────────────────────────────────────────────────

  time.timeZone = "America/New_York";

  # ── Packages ──────────────────────────────────────────────────────────────

  environment.systemPackages = with pkgs; [
    # Editors
    nano

    # Utilities
    git
    curl
    wget
    htop
    tree

    # Languages
    go
    nodejs
    python3

    # Secrets management (CLI only — for managing NAS secrets from this machine)
    agenix.packages.${pkgs.stdenv.hostPlatform.system}.default

    # Unstable
    pkgs-unstable.claude-code
  ];

  # ── Shell ─────────────────────────────────────────────────────────────────

  programs.fish.enable = true;
  # To set fish as your default shell, run once after first activation:
  #   chsh -s /run/current-system/sw/bin/fish

  # ── Nix Settings ──────────────────────────────────────────────────────────

  nix.settings.experimental-features = [ "nix-command" "flakes" ];

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
      # "obsidian"   # running beta — manage manually
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

  # ── System ────────────────────────────────────────────────────────────────

  # Used for backwards compatibility — set at first activation, do NOT change.
  system.stateVersion = 5;
}
