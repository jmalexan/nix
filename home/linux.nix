{ config, pkgs, lib, ... }:

{
  imports = [ ./common.nix ];

  # ── SSH ───────────────────────────────────────────────────────────────────

  programs.ssh.matchBlocks = {
    "jmalexan" = {
      hostname = "159.65.110.8";
      user = "jmalexan";
    };
    "unifi router unifi.lan router.lan" = {
      hostname = "unifi.lan";
      user = "root";
      extraOptions = {
        HostkeyAlgorithms = "+ssh-rsa";
        PubkeyAcceptedAlgorithms = "+ssh-rsa";
      };
    };
  };
}
