{ ... }: {
  # Pin UIDs/GIDs so file ownership stays consistent across rebuilds and migrations.
  users.users.jellyfin.uid = 997;
  users.groups.jellyfin.gid = 997;

  services.jellyfin = {
    enable = true;
    dataDir  = "/Data/smb/Internal/Services/jellyfin/config";
    cacheDir = "/Data/smb/Internal/Services/jellyfin/cache";
    openFirewall = true;  # TCP 8096 (HTTP), 8920 (HTTPS)
  };

  # Grant jellyfin access to the GPU for NVENC transcoding
  users.users.jellyfin.extraGroups = [ "video" "render" "media" ];
}
