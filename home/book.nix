{ config, pkgs, lib, ... }:

{
  imports = [ ./common.nix ];

  # ── Git ───────────────────────────────────────────────────────────────────

  programs.git.settings.init.defaultBranch = "main";

  # ── Fish ──────────────────────────────────────────────────────────────────

  programs.fish.loginShellInit = ''
    eval (/opt/homebrew/bin/brew shellenv)
  '';

  # ── SSH ───────────────────────────────────────────────────────────────────

  programs.ssh.settings = {
    "*" = {
      IdentityFile = "~/.ssh/id_ed25519";
      AddKeysToAgent = "yes";
      UseKeychain = "yes";
    };
    "nasa nasa.lan" = {
      HostName = "nasa.lan";
      User = "jmalexan";
      ForwardAgent = true;
    };
    "home home.nasa.lan" = {
      HostName = "home.nasa.lan";
      User = "jmalexan";
    };
    "htpc htpc.lan" = {
      HostName = "htpc.lan";
      User = "jmalexan";
    };
    "pihole pihole.lan" = {
      HostName = "pihole.lan";
      User = "jmalexan";
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
