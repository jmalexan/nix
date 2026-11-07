{
  config,
  lib,
  pkgs,
  pkgs-unstable,
  claude-code-pkg,
  home-manager-stable,
  rex,
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

    config = { pkgs, ... }: {
      imports = [
        ../../../modules/dev-environment.nix
        ../../../modules/linux-server.nix
        (import ../../../modules/rex.nix { inherit rex vars; })
        ../../../modules/trust-private-ca.nix
        home-manager-stable.nixosModules.home-manager
      ];

      _module.args = { inherit pkgs-unstable claude-code-pkg; };
      networking.hostName = "home";
      programs.agentTools.enable = false;

      # Serve Rex without a TUN device or extra container device permissions.
      services.tailscale.interfaceName = "userspace-networking";

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

  systemd.services."container@home" = {
    # Guest sessions can need 90s to stop. Leave time for nspawn to finish
    # shutdown and release its mounts/network before the host kills it.
    serviceConfig = {
      TimeoutStopSec = "3min";
      ExecStopPost = "${config.systemd.package}/bin/systemd-nspawn --cleanup --machine=%i --directory=/var/lib/nixos-containers/%i";
    };

    # Recover leftovers from an interrupted nspawn. The upstream pre-start
    # only removes the main veth when an explicit IP address is configured;
    # this container uses hostBridge and obtains its address with DHCP.
    preStart = lib.mkAfter ''
      ${config.systemd.package}/bin/systemd-nspawn --cleanup --machine=home --directory=/var/lib/nixos-containers/home
      if ${pkgs.iproute2}/bin/ip link show dev vb-home > /dev/null 2>&1; then
        ${pkgs.iproute2}/bin/ip link delete dev vb-home
      fi
    '';
  };
}
