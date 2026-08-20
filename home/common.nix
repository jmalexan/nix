{ pkgs, vars, ... }:

{
  imports = [ ../modules/starship.nix ];

  home.username = vars.user.name;
  home.homeDirectory =
    if pkgs.stdenv.isDarwin then "/Users/${vars.user.name}" else "/home/${vars.user.name}";

  # ── Git ───────────────────────────────────────────────────────────────────

  programs.git = {
    enable = true;
    settings.user.name = vars.user.fullName;
    settings.user.email = vars.user.email;
    settings.pull.rebase = false;
    settings.push.autoSetupRemote = true;
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

}
