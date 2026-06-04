{ config, pkgs, lib, ... }:

{
  imports = [ ./common.nix ];

  programs.tmux = {
    enable = true;
    terminal = "tmux-256color";
  };

  # Auto-attach (or create) a tmux session named "main" on SSH login.
  programs.fish.interactiveShellInit = ''
    if status is-interactive
        and set -q SSH_CONNECTION
        and not set -q TMUX
        and not set -q INSIDE_EMACS
        and not string match -q 'screen*' -- $TERM
        exec tmux new-session -A -s main
    end
  '';
}
