{ ... }: {
  # Prowlarr is an indexer manager — it routes searches between the *arr apps
  # and your torrent indexers.  It doesn't touch media files, so it needs no
  # access to /Data/smb and runs fine with systemd's DynamicUser isolation.
  services.prowlarr = {
    enable = true;
    dataDir = "/Data/smb/Internal/Services/prowlarr";
    openFirewall = false;
  };
}
