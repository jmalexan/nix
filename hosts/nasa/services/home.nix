{ pkgs, pkgs-unstable, home-manager-stable, ... }: {
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
      imports = [
        (import ../../../modules/dev-environment.nix pkgs-unstable)
        ../../../modules/linux-server.nix
        home-manager-stable.nixosModules.home-manager
      ];

      networking.hostName = "home";

      # eth0 is the veth interface the container sees when joined to a bridge.
      networking.useDHCP = false;
      networking.interfaces.eth0.useDHCP = true;

      time.timeZone = "America/New_York";

      users.users.jmalexan = {
        isNormalUser = true;
        extraGroups = [ "wheel" ];
        shell = pkgs.fish;
        openssh.authorizedKeys.keys = import ../../../users/authorized-keys.nix;
      };

      home-manager = {
        useGlobalPkgs = true;
        useUserPackages = true;
        users.jmalexan = import ../../../home/linux.nix;
      };

      networking.useHostResolvConf = false;
      services.resolved.enable = true;

      networking.firewall.allowedTCPPorts = [ 22 ];

      programs.nix-ld.enable = true;

      system.stateVersion = "25.11";
    };
  };
}
