{ config, pkgs, lib, ... }:

{
  imports = [ ../modules/starship.nix ];

  home.username = "jmalexan";
  home.homeDirectory = if pkgs.stdenv.isDarwin then "/Users/jmalexan" else "/home/jmalexan";

  # ── Git ───────────────────────────────────────────────────────────────────

  programs.git = {
    enable = true;
    settings.user.name = "Jonathan Alexander";
    settings.user.email = "me@jmalexan.com";
    settings.pull.rebase = false;
  };

  # ── Fish ──────────────────────────────────────────────────────────────────

  programs.fish = {
    enable = true;
    # Migrate content from ~/.config/fish/config.fish here.
    # shellAliases = { ... };
    # interactiveShellInit = ''...'';
  };

  # ── direnv ────────────────────────────────────────────────────────────────

  programs.direnv = {
    enable = true;
    nix-direnv.enable = true;
  };

  # ── SSH ───────────────────────────────────────────────────────────────────

  programs.ssh = {
    enable = true;
    enableDefaultConfig = false;
  };

  # ── State Version ─────────────────────────────────────────────────────────

  # Set at first activation — do NOT change.
  home.stateVersion = "25.11";
}
