# Raspberry Pi 4 Model B (8 GB), dedicated Ethernet DNS appliance.
{
  config,
  modulesPath,
  pkgs,
  vars,
  ...
}:
{
  imports = [
    (modulesPath + "/installer/sd-card/sd-image-aarch64.nix")
    ../../modules/linux-server.nix
    ../../modules/rex.nix
  ];

  nixpkgs.hostPlatform = "aarch64-linux";
  networking.hostName = "pihole";
  networking.useDHCP = false;
  networking.useNetworkd = true;
  systemd.network.networks."10-ethernet" = {
    matchConfig.MACAddress = "d8:3a:dd:6d:6b:12";
    networkConfig = {
      DHCP = "ipv4";
      IPv6AcceptRA = true;
    };
    # Preserve the existing router reservation, independent of interface naming.
    dhcpV4Config.ClientIdentifier = "mac";
  };
  # Independent bootstrap DNS: rebuilding must work even if local FTL is down.
  networking.nameservers = [
    "1.1.1.1"
    "1.0.0.1"
  ];
  services.resolved.enable = false;
  # Rex uses Tailscale Serve. Keep this DNS appliance's resolver independent.
  services.tailscale = {
    openFirewall = true;
    extraSetFlags = [ "--accept-dns=false" ];
  };
  time.timeZone = vars.timeZone;

  users.users.${vars.user.name} = {
    isNormalUser = true;
    description = vars.user.fullName;
    extraGroups = [ "wheel" ];
    openssh.authorizedKeys.keys = import ../../users/authorized-keys.nix;
  };
  nix.settings.experimental-features = [
    "nix-command"
    "flakes"
  ];
  nix.settings.max-jobs = 1;
  nix.settings.cores = 4;
  environment.systemPackages = [
    pkgs.git
    pkgs.dig
  ];

  # Pull approved main revisions locally; this host needs no CI SSH access.
  system.autoUpgrade = {
    enable = true;
    flake = "${vars.repository}/main#pihole";
    upgrade = false; # Honour flake.lock; do not independently update inputs.
    operation = "switch";
    dates = "*:0/15";
    randomizedDelaySec = "2min";
    allowReboot = false;
    flags = [
      "--max-jobs"
      "1"
      "--cores"
      "2"
    ];
  };

  services.pihole-ftl = {
    enable = true;
    # Ports are limited to the physical Ethernet interface below.
    lists = [ { url = "https://big.oisd.nl"; } ];
    settings = {
      dns = {
        upstreams = [
          "1.1.1.1"
          "1.0.0.1"
          "2606:4700:4700::1111"
          "2606:4700:4700::1001"
        ];
        hosts = import ./records.nix;
        revServers = [ "true,10.0.0.0/23,10.0.0.1#53" ];
        listeningMode = "LOCAL";
      };
      dhcp.active = false;
      # Avoid competing with the router for NTP service.
      ntp.ipv4.active = false;
      ntp.ipv6.active = false;
    };
  };
  # The native module loads lists at startup; schedule ongoing list refreshes.
  systemd.services.pihole-gravity = {
    description = "Refresh Pi-hole blocklists";
    requires = [ "pihole-ftl.service" ];
    after = [
      "network-online.target"
      "pihole-ftl-setup.service"
    ];
    wants = [ "network-online.target" ];
    serviceConfig = {
      Type = "oneshot";
      User = "pihole";
      # The upstream wrapper has no shebang; systemd needs an explicit interpreter.
      ExecStart = "${pkgs.bash}/bin/bash ${config.services.pihole-ftl.pihole}/bin/pihole -g";
    };
  };
  systemd.timers.pihole-gravity = {
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "weekly";
      RandomizedDelaySec = "1h";
      Persistent = true;
    };
  };
  services.pihole-web = {
    enable = true;
    hostName = "pihole.lan";
    ports = [ "127.0.0.1:80" ];
  };
  # Optional runtime secret, kept out of the store. UI is SSH-tunnel-only.
  systemd.services.pihole-ftl.serviceConfig.EnvironmentFile = "-/var/lib/pihole-web.env";
  # Pin the interface name so firewall rules follow the matched NIC.
  systemd.network.links."10-ethernet" = {
    matchConfig.MACAddress = "d8:3a:dd:6d:6b:12";
    linkConfig.Name = "end0";
  };
  networking.firewall.interfaces.end0 = {
    allowedTCPPorts = [ 53 ];
    allowedUDPPorts = [ 53 ];
  };
  system.stateVersion = "26.05";
}
