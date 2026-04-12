{ ... }: {
  # Add to the media group so Lidarr can read /Data/smb/Torrents and write
  # to /Data/smb/Media/Music (both owned by or group-accessible via media).
  users.users.lidarr.extraGroups = [ "media" ];

  services.lidarr = {
    enable = true;
    dataDir = "/Data/smb/Internal/Services/lidarr";
    openFirewall = false;
  };
}
