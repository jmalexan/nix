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

  programs.ssh.matchBlocks = {
    "*" = {
      identityFile = "~/.ssh/id_ed25519";
      extraOptions = {
        AddKeysToAgent = "yes";
        UseKeychain = "yes";
      };
    };
    "nasa nasa.lan" = {
      hostname = "nasa.lan";
      user = "jmalexan";
      forwardAgent = true;
    };
    home = {
      hostname = "home.nasa.lan";
      user = "jmalexan";
    };
    pihole = {
      hostname = "pihole.lan";
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
