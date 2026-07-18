# Shared baseline imported by every NixOS host in this flake.
# Pulls in the cross-platform dev environment and the Linux server defaults,
# then adds the things every Linux host of mine wants: bootloader, network
# manager, my user, and a couple of extra packages.
{ config, lib, pkgs, pkgs-unstable, claude-code-pkg, agenix, ... }:

{
  imports = [
    (import ./dev-environment.nix pkgs-unstable claude-code-pkg)
    ./linux-server.nix
  ];

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
    extraGroups = [ "wheel" "networkmanager" "hass" "jellyfin" "qbittorrent" "immich" "media" ];
    shell = pkgs.fish;
    home = "/home/jmalexan";
    openssh.authorizedKeys.keys = import ../users/authorized-keys.nix;
  };

  # ── Packages ──────────────────────────────────────────────────────────────

  environment.systemPackages = with pkgs; [
    screen
    agenix.packages.${pkgs.stdenv.hostPlatform.system}.default
  ];

  # ── Nix Settings ──────────────────────────────────────────────────────────

  nix.gc = {
    automatic = true;
    dates = "weekly";
    options = "--delete-older-than 14d";
  };

  # ── State Version ─────────────────────────────────────────────────────────

  # Set at install time — do NOT change.
  system.stateVersion = "25.11";
}
