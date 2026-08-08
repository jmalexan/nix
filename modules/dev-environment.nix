# Cross-platform shared base for any host that has a human shell on it.
{
  pkgs,
  pkgs-unstable,
  claude-code-pkg,
  ...
}:

{
  programs.fish.enable = true;

  nix.settings.experimental-features = [
    "nix-command"
    "flakes"
  ];

  nixpkgs.config.allowUnfree = true;

  environment.systemPackages = with pkgs; [
    git
    curl
    wget
    htop
    nano
    tree
    pkgs-unstable.codex
    claude-code-pkg
  ];
}
