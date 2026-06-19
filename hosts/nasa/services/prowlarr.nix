{ ... }: {
  # Prowlarr is an indexer manager — it routes searches between the *arr apps
  # and your torrent indexers.  It doesn't touch media files, so it needs no
  # access to /Data/smb and runs fine with systemd's DynamicUser isolation.
  services.prowlarr = {
    enable = true;
    dataDir = "/Data/smb/Internal/Services/prowlarr";
    openFirewall = false;
  };

  # Prowlarr is the app that actually queries the torrent indexers/trackers, so
  # route it through the Mullvad VPN namespace (the same one qbittorrent uses)
  # to keep those queries off the ISP link.  nginx reaches the web UI via the
  # veth at 10.200.200.2:9696; the *arr apps reach it on localhost (shared netns).
  systemd.services.prowlarr = {
    after    = [ "mullvad-netns.service" ];
    requires = [ "mullvad-netns.service" ];
    serviceConfig.NetworkNamespacePath = "/run/netns/mullvad";
  };
}
