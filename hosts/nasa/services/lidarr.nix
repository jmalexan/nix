{ ... }: {
  # Add to the media group so Lidarr can read /Data/smb/Torrents and write
  # to /Data/smb/Media/Music (both owned by or group-accessible via media).
  users.users.lidarr.extraGroups = [ "media" ];

  services.lidarr = {
    enable = true;
    dataDir = "/Data/smb/Internal/Services/lidarr";
    openFirewall = false;
  };

  # Route all outbound traffic through the Mullvad VPN namespace (the same one
  # qbittorrent uses) so indexer/tracker queries never traverse the ISP link.
  # nginx reaches the web UI via the veth at 10.200.200.2:8686.  Inter-app
  # comms (Prowlarr, qbittorrent) stay on localhost since they share this netns.
  systemd.services.lidarr = {
    after    = [ "mullvad-netns.service" ];
    requires = [ "mullvad-netns.service" ];
    serviceConfig.NetworkNamespacePath = "/run/netns/mullvad";
  };
}
