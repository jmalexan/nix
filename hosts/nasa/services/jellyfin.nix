{ ... }: {
  services.jellyfin = {
    enable = true;
    dataDir  = "/Data/smb/Internal/Services/jellyfin/config";
    cacheDir = "/Data/smb/Internal/Services/jellyfin/cache";
    openFirewall = true;  # TCP 8096 (HTTP), 8920 (HTTPS)
  };
}
