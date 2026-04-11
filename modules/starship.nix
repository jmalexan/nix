# Starship settings shared by home-manager hosts and the home NixOS
# container. Both NixOS and home-manager expose programs.starship with
# the same { enable, settings } interface, so this module can be
# imported in either context.
{ lib, ... }: {
  programs.starship = {
    enable = true;
    settings = {
      # Mid-tone palette: each segment background is luminance ~0.30–0.40 so it
      # stays visible against both dark and light terminal backgrounds, and dark
      # text on top has good contrast in both modes.
      palette = "muted";

      palettes.muted = {
        purple = "#9080c4";  # os/hostname
        teal   = "#5a9eb3";  # directory
        pink   = "#c66b9c";  # git
        green  = "#5fa860";  # langs + character success
        amber  = "#b08840";  # cmd_duration
        red    = "#e06070";  # character error (text only, no bg)
        base   = "#1e1e2e";  # dark text on colored segments
      };

      format = lib.concatStrings [
        "╭─"
        "$os"
        "$hostname"
        "[](fg:prev_bg bg:teal)"
        "$directory"
        "([](fg:prev_bg bg:pink)$git_branch$git_status)"
        "[](fg:prev_bg)"
        "$fill"
        "([](fg:green)\${custom.langs})"
        "([](fg:amber bg:prev_bg)$cmd_duration)"
        "$line_break"
        "$character"
      ];

      os = {
        disabled = false;
        format = "[ $symbol]($style)";
        style = "bg:purple fg:base";
        symbols = {
          Macos = "";
          NixOS = "";
          Linux = "";
        };
      };

      hostname = {
        ssh_only = false;
        style = "bg:purple fg:base";
        format = "[ $hostname ]($style)";
      };

      directory = {
        style = "bg:teal fg:base";
        format = "[ $path ]($style)";
        truncation_length = 3;
        truncation_symbol = "…/";
      };

      git_branch = {
        style = "bg:pink fg:base";
        format = "[ $symbol$branch ]($style)";
      };

      git_status = {
        style = "bg:pink fg:base";
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
        style = "bg:green fg:base";
        format = "[ $output ]($style)";
      };

      fill = {
        symbol = " ";
      };

      cmd_duration = {
        format = "[ $duration ]($style)";
        style = "bg:amber fg:base";
        min_time = 2000;
      };

      character = {
        success_symbol = "╰─[❯](green)";
        error_symbol = "╰─[❯](red)";
      };
    };
  };
}
