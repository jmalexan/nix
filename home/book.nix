{ config, pkgs, lib, ... }:

{
  imports = [ ./common.nix ];

  # ── Fish ──────────────────────────────────────────────────────────────────

  programs.fish.loginShellInit = ''
    eval (/opt/homebrew/bin/brew shellenv)
  '';

  # ── SSH ───────────────────────────────────────────────────────────────────

  programs.ssh.matchBlocks = {
    "nasa nasa.lan" = {
      hostname = "nasa.lan";
      user = "jmalexan";
    };
    "home home.nasa.lan" = {
      hostname = "home.nasa.lan";
      user = "jmalexan";
    };
  };

  # ── Ghostty ───────────────────────────────────────────────────────────────

  programs.ghostty = {
    enable = true;
    package = null;  # installed via Homebrew cask on macOS
    settings = {
      theme = "dark:One Half Dark,light:One Half Light";
      font-family = "Fira Code Retina";
      shell-integration-features = "ssh-env";
    };
  };
}
