# Cross-platform shared base for any host that has a human shell on it.
# Works on both NixOS and nix-darwin. Imported as `import ... pkgs-unstable`
# so the caller doesn't need to thread pkgs-unstable through specialArgs.
pkgs-unstable: { pkgs, claude-code-pkg, ... }: {
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
