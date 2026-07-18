# Cross-platform shared base for any host that has a human shell on it.
# Works on both NixOS and nix-darwin. Imported as
# `import ... pkgs-unstable claude-code-pkg` so the caller doesn't need to
# thread these through specialArgs (and so it works inside NixOS containers,
# which don't inherit the outer specialArgs).
pkgs-unstable: claude-code-pkg: { pkgs, ... }: {
  programs.fish.enable = true;

  nix.settings.experimental-features = [ "nix-command" "flakes" ];

  nixpkgs.config.allowUnfree = true;

  environment.systemPackages = with pkgs; [
    git
    curl
    wget
    htop
    nano
    tree
    claude-code-pkg
  ];
}
