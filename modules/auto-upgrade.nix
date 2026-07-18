# Pull-based auto-upgrade for NixOS hosts.
#
# Every host that imports this polls the (public) GitHub repo every 15 minutes
# and rebuilds itself from the latest `main`. The flake ref is derived from the
# hostname, so it Just Works as long as the hostname matches the
# `nixosConfigurations.<name>` attribute (nasa, htpc).
#
# Safety: `switch` only activates a generation if the build succeeds, so a
# broken commit can't take a machine down — the timer just skips that cycle and
# the running generation stays put. `allowReboot = false` means a kernel/initrd
# change is staged for the next manual reboot rather than rebooting under you.
#
# Manual deploys still work exactly as before:
#   nixos-rebuild switch --flake .#<host>
#
# ...or force an early update check on the timer's behalf with `update-now`
# (defined below), which pulls latest from GitHub and switches immediately.
{ config, pkgs, ... }:

{
  system.autoUpgrade = {
    enable = true;

    flake = "github:jmalexan/nix#${config.networking.hostName}";

    # NOTE: the module already appends `--refresh` for flake upgrades, so the
    # 15-minute timer bypasses nix's 1h tarball cache and sees new commits.
    dates = "*:0/15";        # every 15 minutes
    randomizedDelaySec = "45";
    operation = "switch";
    allowReboot = false;
  };

  # Shortcut to force the update the timer would otherwise do on its next tick.
  # nixos-rebuild picks the config attr from the hostname, so no #host needed.
  # Extra args pass through, e.g. `update-now --show-trace`.
  environment.systemPackages = [
    (pkgs.writeShellScriptBin "update-now" ''
      echo "→ Pulling latest config from GitHub and switching…"
      exec sudo nixos-rebuild switch --refresh --flake github:jmalexan/nix "$@"
    '')
  ];
}
