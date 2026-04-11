{ config, pkgs, lib, ... }:

{
  imports = [ ./common.nix ];

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

  # Uncomment and populate once ready to migrate ~/.config/ghostty/config:
  # xdg.configFile."ghostty/config".text = ''
  #   ...
  # '';
}
