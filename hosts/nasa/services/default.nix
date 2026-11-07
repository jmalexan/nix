{ config, ... }: {
  services.gitBroker.enable = true;
  services.approvals = {
    enable = true;
    sshGate.enable = true;
    notifications.enable = true;
    vapidPublicKey = "BAPjwCWe17dLUMj9Y4LmzfrbH7aGbVebTyvGjFntCzv3Z7J2X4Ii_p1beTr3nFSS8-bgDZx4Cepo2ZNE4Qg6m4o";
  };
  services.notificationBridge = {
    enable = true;
    origin = "https://notifications.nasa.jmalexan.com";
    servicesFile = "/var/lib/microapp-secrets/notifications/services.json";
    apnsKeyFile = config.age.secrets.notifications-apns.path;
    apnsKeyId = "483X3U5W26";
    appleTeamId = "KMY78Z7HFB";
  };
  # Explicit inventory: adding a .nix file to this directory must not silently
  # enable a service. Keep related stacks adjacent so the host topology is easy
  # to scan during review.
  imports = [
    # Storage, access, and lifecycle
    ./zfs.nix
    ./backup.nix
    ./backups.nix
    ./cert-renew.nix
    ./ddns.nix
    ./tailscale.nix
    ./nginx.nix
    ./samba.nix
    ./radicale.nix

    # Container runtime and development infrastructure
    ./containers.nix
    ./gitlab-runner.nix
    ./git-broker.nix
    ./updates-dashboard.nix
    ./approvals.nix
    ./notifications.nix

    # Media acquisition and serving
    ./mullvad.nix
    ./flaresolverr.nix
    ./prowlarr.nix
    ./arr-stack.nix
    ./qbittorrent.nix
    ./seerr.nix
    ./jellyfin.nix
    ./immich.nix
    ./romm-igir.nix
    ./romm.nix
    ./bookorbit.nix
    ./music-covers.nix

    # Home automation and cameras
    ./mqtt.nix
    ./homeassistant.nix
    ./eufy-security.nix
    ./ring-mqtt.nix
    ./frigate.nix

    # Local inference
    ./inference.nix
  ];

  # The explicit inventory is intentionally safer than importing every file in
  # this directory, but an accidental omission must fail evaluation instead of
  # silently removing a stateful application from the deployed system.
  assertions = [
    {
      assertion = config.virtualisation.oci-containers.containers ? immich-server;
      message = "The NAS service inventory must include the Immich stack";
    }
    {
      assertion = config.virtualisation.oci-containers.containers ? romm;
      message = "The NAS service inventory must include RomM";
    }
  ];
}
