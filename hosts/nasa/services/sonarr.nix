{ ... }: {
  # Add to the media group so Sonarr can read /Data/smb/Torrents and write
  # to /Data/smb/Media/TV Shows (both owned by or group-accessible via media).
  users.users.sonarr.extraGroups = [ "media" ];

  services.sonarr = {
    enable = true;
    dataDir = "/Data/smb/Internal/Services/sonarr";
    openFirewall = false;
  };
}
