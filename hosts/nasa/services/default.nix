{ ... }: {
  # Explicit inventory: adding a .nix file to this directory must not silently
  # enable a service. Keep related stacks adjacent so the host topology is easy
  # to scan during review.
  imports = [
    # Storage, access, and lifecycle
    ./zfs.nix
    ./backup.nix
    ./cert-renew.nix
    ./ddns.nix
    ./tailscale.nix
    ./nginx.nix
    ./samba.nix

    # Container runtime and development infrastructure
    ./containers.nix
    ./gitlab-runner.nix

    # Media acquisition and serving
    ./mullvad.nix
    ./flaresolverr.nix
    ./prowlarr.nix
    ./arr-stack.nix
    ./qbittorrent.nix
    ./seerr.nix
    ./jellyfin.nix
    ./calibre.nix
    ./music-covers.nix

    # Home automation and cameras
    ./mqtt.nix
    ./homeassistant.nix
    ./eufy-security.nix
    ./ring-mqtt.nix
    ./go2rtc.nix
    ./frigate.nix

    # Local inference
    ./inference.nix
  ];
}
