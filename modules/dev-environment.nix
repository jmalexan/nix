# Cross-platform shared base for any host that has a human shell on it.
{
  config,
  lib,
  pkgs,
  pkgs-unstable,
  claude-code-pkg,
  ...
}:

{
  options.programs.agentTools.enable = lib.mkOption {
    type = lib.types.bool;
    default = true;
    description = "Install the shared Codex and Claude Code clients.";
  };

  config = {
    programs.fish.enable = true;

    nix.settings.experimental-features = [
      "nix-command"
      "flakes"
    ];

    nixpkgs.config.allowUnfree = true;

    environment.systemPackages =
      with pkgs;
      [
        git
        curl
        wget
        htop
        nano
        tree
      ]
      ++ lib.optionals config.programs.agentTools.enable [
        pkgs-unstable.codex
        claude-code-pkg
      ]
      ++ lib.optionals stdenv.hostPlatform.isLinux [ bubblewrap ];
  };
}
