{ pkgs, ... }: {
  # ── Bridge networking ──────────────────────────────────────────────────────
  # enp5s0 joins br0 so nasa, the home container, and all LAN devices can
  # reach each other freely. NetworkManager is told to leave both interfaces
  # alone; NixOS networking scripts manage them instead.
  networking.bridges.br0.interfaces = [ "enp5s0" ];
  networking.interfaces.br0.useDHCP = true;
  networking.networkmanager.unmanaged = [ "enp5s0" "br0" ];

  containers.home = {
    autoStart = true;
    privateNetwork = true;

    # Attach the container's veth to br0, putting it on the same LAN segment.
    hostBridge = "br0";

    config = { pkgs, ... }: {
      networking.hostName = "home";

      # eth0 is the veth interface the container sees when joined to a bridge.
      networking.useDHCP = false;
      networking.interfaces.eth0.useDHCP = true;

      time.timeZone = "America/New_York";

      security.sudo.wheelNeedsPassword = false;

      users.users.jmalexan = {
        isNormalUser = true;
        extraGroups = [ "wheel" ];
        shell = pkgs.fish;
        openssh.authorizedKeys.keys = [
          "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABgQCsrxncbMeTHpAQZCb8depAIv2eUZd41d/z56dsS4L49ub6KRqh1XJsowUOWwopiHFD7HeNNxs64C+jdtRZxOJ2HKiijREpOC+4Ogy1zD8ClNGsZ6Gq2vxeedxPueXpMxs9L+N9GrDIsXDWH0kDFdbXou+XSmg6M8XmtTv2md9piANzzffOx2Jms+Y2m6Z+oMmwXeq0/vTQBhNah2T5ekc0Lwd9h9x7wHEOCjZjadgicWlJxAgAkzm1fKQ3IFor4recLWGCR0hJD45qNAfwxIrzAibvfsovuXmxh559C3WXjW/OEq9fCu8pIcZyrY3yN7ITMw9JgHEaCop0voIMCp7LUKjl5yqK1BLIjZpw3JUDp7UJkIjWHNDiIagpBxNEAvxRwewuJeUyy2L6QSC5+KYjVbz3oBpRvBkDTHmC/WRcdyAA/J91kzZz3eQNU/Kv30LtqYWRSWOEtN1sXja+zMFE3D4nEkbJdvRN3ARVLo6pW3tJAj4BAMu6MunnVhuOjHk= jmalexan@Book.local"
          "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAINgAalZOAJUM/O8gwhWmsEnbmUV8qiAFvTja8WABC4O5 rootshell"
        ];
      };

      environment.systemPackages = with pkgs; [
        git
        curl
        wget
        htop
        nano
        tree
        screen
      ];

      programs.fish.enable = true;

      services.openssh = {
        enable = true;
        settings = {
          PasswordAuthentication = false;
          PermitRootLogin = "no";
        };
      };

      networking.firewall.allowedTCPPorts = [ 22 ];

      nix.settings.experimental-features = [ "nix-command" "flakes" ];

      system.stateVersion = "25.11";
    };
  };
}
