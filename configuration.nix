{ config, lib, pkgs, pkgs-unstable, ... }:

{
  # ── Boot ──────────────────────────────────────────────────────────────────

  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;

  # ── Networking ────────────────────────────────────────────────────────────

  networking.networkmanager.enable = true;

  # ── Locale & Time ─────────────────────────────────────────────────────────

  time.timeZone = "America/New_York";

  # ── Users ─────────────────────────────────────────────────────────────────

  users.users.jmalexan = {
    isNormalUser = true;
    description = "Jonathan";
    extraGroups = [ "wheel" "networkmanager" ];
    shell = pkgs.fish;
    home = "/home/jmalexan";
    packages = with pkgs; [
      tree
    ];
  };

  # ── Packages ──────────────────────────────────────────────────────────────

  nixpkgs.config.allowUnfree = true;

  environment.systemPackages = with pkgs; [
    # Editors
    nano
    # vim

    # Utilities
    git
    screen
    curl
    wget
    htop

    # Nix tooling
    # nix-index       # builds a local index for nix-locate (find which package owns a file)
    # nh              # nicer `nixos-rebuild` wrapper with diffs    

    # Unstable
    pkgs-unstable.claude-code
  ];

  # ── Shell ─────────────────────────────────────────────────────────────────

  programs.fish.enable = true;

  # ── Nix Settings ──────────────────────────────────────────────────────────

  nix.settings.experimental-features = [ "nix-command" "flakes" ];

  # Automatic garbage collection — keeps the store from growing unbounded
  nix.gc = {
    automatic = true;
    dates = "weekly";
    options = "--delete-older-than 14d";
  };

  # ── Services ──────────────────────────────────────────────────────────────

  systemd.services.claude-remote-control = {
    description = "Claude Code Remote Control";
    wantedBy = [ "multi-user.target" ];
    after = [ "network.target" ];
    environment = {
      HOME = "/home/jmalexan";
    };
    serviceConfig = {
      User = "jmalexan";
      ExecStart = "${pkgs-unstable.claude-code}/bin/claude remote-control";
      WorkingDirectory = "/home/jmalexan/claude";
      Restart = "on-failure";
      RestartSec = "5s";
    };
  };

  services.openssh = {
    enable = true;
    settings = {
      PasswordAuthentication = false;  # key-based auth only (set up keys first!)
      PermitRootLogin = "no";
    };
  };

  # Automatic security updates for NixOS itself
  # system.autoUpgrade = {
  #   enable = true;
  #   allowReboot = false;
  # };

  # ── Firewall ──────────────────────────────────────────────────────────────

  # Firewall is enabled by default; open ports as needed:
  # networking.firewall.allowedTCPPorts = [ 80 443 ];

  # ── State Version ─────────────────────────────────────────────────────────

  # Set at install time — do NOT change.
  system.stateVersion = "25.11";
}
