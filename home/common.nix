{ config, pkgs, lib, ... }:

{
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

  # ── Starship ──────────────────────────────────────────────────────────────

  programs.starship = {
    enable = true;
    settings = {
      format = lib.concatStrings [
        "╭─"
        "$os"
        "$hostname"
        "[](fg:prev_bg bg:cyan)"
        "$directory"
        "([](fg:prev_bg bg:purple)$git_branch$git_status)"
        "[](fg:prev_bg)"
        "$fill"
        "([](fg:green)\${custom.langs})"
        "([](fg:yellow bg:prev_bg)$cmd_duration)"
        "$line_break"
        "$character"
      ];

      os = {
        disabled = false;
        format = "[ $symbol]($style)";
        style = "bg:blue";
        symbols = {
          Macos = "";
          NixOS = "";
          Linux = "";
        };
      };

      hostname = {
        ssh_only = false;
        style = "bg:blue";
        format = "[ $hostname ]($style)";
      };

      directory = {
        style = "bg:cyan";
        format = "[ $path ]($style)";
        truncation_length = 3;
        truncation_symbol = "…/";
      };

      git_branch = {
        style = "bg:purple";
        format = "[ $symbol$branch ]($style)";
      };

      git_status = {
        style = "bg:purple";
        format = "[$all_status$ahead_behind ]($style)";
      };

      custom.langs = {
        when = "test -f package.json || test -f go.mod || test -f requirements.txt || test -f pyproject.toml";
        command = ''
          out=""
          [ -f package.json ] && out="$out  $(node --version 2>/dev/null | cut -c2-)"
          [ -f go.mod ] && out="$out  $(go version 2>/dev/null | awk '{print $3}' | cut -c3-)"
          { [ -f requirements.txt ] || [ -f pyproject.toml ]; } && out="$out  $(python3 --version 2>/dev/null | awk '{print $2}')"
          printf "%s" "$out"
        '';
        shell = [ "sh" ];
        style = "bg:green";
        format = "[ $output ]($style)";
      };

      fill = {
        symbol = " ";
      };

      cmd_duration = {
        format = "[ $duration ]($style)";
        style = "bg:yellow";
        min_time = 2000;
      };

      character = {
        success_symbol = "╰─[❯](green)";
        error_symbol = "╰─[❯](red)";
      };
    };
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
