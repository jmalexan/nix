{
  pkgs-unstable,
  claude-code-pkg,
  home-manager-stable,
  vars,
  ...
}:
{
  # ── Bridge networking ──────────────────────────────────────────────────────
  # enp5s0 joins br0 so nasa, the home container, and all LAN devices can
  # reach each other freely. NetworkManager is told to leave both interfaces
  # alone; NixOS networking scripts manage them instead.
  networking.bridges.br0.interfaces = [ "enp5s0" ];
  networking.interfaces.br0.useDHCP = true;
  networking.networkmanager.unmanaged = [
    "enp5s0"
    "br0"
  ];

  # br0 is the trusted home LAN segment — skip firewall rules on it so
  # LAN-only services (HomeKit bridges, Sonos UPnP, AirPlay, mDNS, etc.)
  # don't need per-port allowlisting.
  networking.firewall.trustedInterfaces = [ "br0" ];

  containers.home = {
    autoStart = true;
    privateNetwork = true;

    # Attach the container's veth to br0, putting it on the same LAN segment.
    hostBridge = "br0";

    # Expose nasa's persistent journal read-only. This lets development tools
    # in the home container inspect host/service logs without giving the
    # container an SSH credential or write access to the host.
    bindMounts."/var/log/nasa-journal" = {
      hostPath = "/var/log/journal";
      isReadOnly = true;
    };

    config = { pkgs, ... }: {
      imports = [
        (
          { pkgs, ... }:
          import ../../../modules/dev-environment.nix {
            inherit pkgs pkgs-unstable claude-code-pkg;
          }
        )
        ../../../modules/linux-server.nix
        ../../../modules/trust-private-ca.nix
        home-manager-stable.nixosModules.home-manager
      ];

      networking.hostName = "home";

      # eth0 is the veth interface the container sees when joined to a bridge.
      networking.useDHCP = false;
      networking.interfaces.eth0.useDHCP = true;
      networking.nameservers = [ "10.0.1.20" ];
      networking.search = [ vars.nasa.domain ];
      networking.dhcpcd.extraConfig = ''
        nohook resolv.conf
      '';

      time.timeZone = vars.timeZone;

      users.users.${vars.user.name} = {
        isNormalUser = true;
        extraGroups = [
          "wheel"
          "systemd-journal"
        ];
        shell = pkgs.fish;
        openssh.authorizedKeys.keys = import ../../../users/authorized-keys.nix;
      };

      environment.systemPackages = [
        (pkgs.writeShellScriptBin "nasa-journalctl" ''
          exec ${pkgs.systemd}/bin/journalctl --directory=/var/log/nasa-journal "$@"
        '')
      ];

      home-manager = {
        useGlobalPkgs = true;
        useUserPackages = true;
        extraSpecialArgs = { inherit vars; };
        users.${vars.user.name} = import ../../../home/linux.nix;
      };

      networking.useHostResolvConf = false;
      services.resolved.enable = true;

      networking.firewall.allowedTCPPorts = [ 22 ];

      programs.nix-ld.enable = true;

      system.stateVersion = "25.11";
    };
  };

  # Ensure the directory shared above exists and survives reboots.
  services.journald.extraConfig = ''
    Storage=persistent
  '';
}
