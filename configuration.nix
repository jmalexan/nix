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
    openssh.authorizedKeys.keys = [
      "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABgQCsrxncbMeTHpAQZCb8depAIv2eUZd41d/z56dsS4L49ub6KRqh1XJsowUOWwopiHFD7HeNNxs64C+jdtRZxOJ2HKiijREpOC+4Ogy1zD8ClNGsZ6Gq2vxeedxPueXpMxs9L+N9GrDIsXDWH0kDFdbXou+XSmg6M8XmtTv2md9piANzzffOx2Jms+Y2m6Z+oMmwXeq0/vTQBhNah2T5ekc0Lwd9h9x7wHEOCjZjadgicWlJxAgAkzm1fKQ3IFor4recLWGCR0hJD45qNAfwxIrzAibvfsovuXmxh559C3WXjW/OEq9fCu8pIcZyrY3yN7ITMw9JgHEaCop0voIMCp7LUKjl5yqK1BLIjZpw3JUDp7UJkIjWHNDiIagpBxNEAvxRwewuJeUyy2L6QSC5+KYjVbz3oBpRvBkDTHmC/WRcdyAA/J91kzZz3eQNU/Kv30LtqYWRSWOEtN1sXja+zMFE3D4nEkbJdvRN3ARVLo6pW3tJAj4BAMu6MunnVhuOjHk= jmalexan@Book.local"
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAINgAalZOAJUM/O8gwhWmsEnbmUV8qiAFvTja8WABC4O5 rootshell"
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
