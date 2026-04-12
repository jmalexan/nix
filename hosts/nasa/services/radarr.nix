{ ... }: {
  # Add to the media group so Radarr can read /Data/smb/Torrents and write
  # to /Data/smb/Media/Movies (both owned by or group-accessible via media).
  users.users.radarr.extraGroups = [ "media" ];

  services.radarr = {
    enable = true;
    dataDir = "/Data/smb/Internal/Services/radarr";
    openFirewall = false;
  };
}
