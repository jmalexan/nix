{ config, pkgs, lib, ... }:

{
  home.username = "jmalexan";
  home.homeDirectory = if pkgs.stdenv.isDarwin then "/Users/jmalexan" else "/home/jmalexan";

  # ── Git ───────────────────────────────────────────────────────────────────

  programs.git = {
    enable = true;
    settings.user.name = "Jonathan Alexander";
    settings.user.email = "me@jmalexan.com";
  };

  # ── Fish ──────────────────────────────────────────────────────────────────

  programs.fish = {
    enable = true;
    # Migrate content from ~/.config/fish/config.fish here.
    # shellAliases = { ... };
    # interactiveShellInit = ''...'';
  };

  # ── SSH ───────────────────────────────────────────────────────────────────

  programs.ssh = {
    enable = true;
    enableDefaultConfig = false;
    matchBlocks."*".identityFile = "~/.ssh/id_ed25519";
  };

  # ── State Version ─────────────────────────────────────────────────────────

  # Set at first activation — do NOT change.
  home.stateVersion = "25.11";
}
