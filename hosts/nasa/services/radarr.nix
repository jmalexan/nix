{ ... }: {
  # Add to the media group so Radarr can read /Data/smb/Torrents and write
  # to /Data/smb/Media/Movies (both owned by or group-accessible via media).
  users.users.radarr.extraGroups = [ "media" ];

  services.radarr = {
    enable = true;
    dataDir = "/Data/smb/Internal/Services/radarr";
    openFirewall = false;
  };

  # Route all outbound traffic through the Mullvad VPN namespace (the same one
  # qbittorrent uses) so indexer/tracker queries never traverse the ISP link.
  # nginx reaches the web UI via the veth at 10.200.200.2:7878.  Inter-app
  # comms (Prowlarr, qbittorrent) stay on localhost since they share this netns.
  systemd.services.radarr = {
    after    = [ "mullvad-netns.service" ];
    requires = [ "mullvad-netns.service" ];
    serviceConfig.NetworkNamespacePath = "/run/netns/mullvad";
  };
}
