{ ... }: {
  # ── Directory creation ────────────────────────────────────────────────────
  # Requires: sudo zfs set acltype=posixacl Data/smb
  #
  # POSIX ACL default entries (set with setfacl -d) on these directories
  # control what permissions new files and subdirectories inherit.
  # Manage ACLs manually as needed:
  #   setfacl -m u:jmalexan:rwx,d:u:jmalexan:rwx <dir>   # add/update an entry
  #   setfacl -R -m u:jmalexan:rwX <dir>                  # backfill existing files
  #   getfacl <path>                                       # inspect current ACL

  # Shared group for services that need read access to media libraries.
  # After adding a user to this group, backfill existing files:
  #   sudo chown -R :media /Data/smb/Media && sudo chmod -R g+rX /Data/smb/Media
  users.groups.media.gid = 993;

  systemd.tmpfiles.rules = [
    "d /Data/smb                                      0755 jmalexan    root  -"
    "d /Data/smb/Internal                             0755 root        root  -"
    "d /Data/smb/Internal/Services                    0755 root        root  -"
    "d /Data/smb/Internal/Services/immich             0750 immich      root  -"
    "d /Data/smb/Internal/Services/jellyfin           0750 jellyfin    root  -"
    "d /Data/smb/Internal/Services/homeassistant      0750 hass        root  -"
    "d /Data/smb/Internal/Services/qbittorrent        0750 qbittorrent root  -"
    # The *arr module tmpfiles rules use single-quoted paths which systemd-tmpfiles
    # does not support, so we create these directories explicitly here instead.
    "d /Data/smb/Internal/Services/sonarr            0700 sonarr      sonarr -"
    "d /Data/smb/Internal/Services/radarr            0700 radarr      radarr -"
    "d /Data/smb/Internal/Services/lidarr            0700 lidarr      lidarr -"
    "d /Data/smb/Media                                2755 root        media -"
    # setgid (02750) ensures new files/dirs created by qbittorrent inherit the
    # media group, so the *arr services and Jellyfin can follow symlinks into
    # this dir.  After changing this, backfill ownership on existing files:
    #   sudo chown -R :media /Data/smb/Torrents
    #   sudo chmod -R g+rw /Data/smb/Torrents   # g+w needed for hardlinks
    "d /Data/smb/Torrents                             02750 qbittorrent media -"
    # *arr services write organised, hardlinked content here; Jellyfin reads it.
    # setgid propagates the media group to all new subdirectories.
    # Migration: move actual media files to /Data/smb/Torrents first, then
    # remove these dirs so tmpfiles recreates them with the correct ownership:
    #   sudo mv /Data/smb/Media/"TV Shows"/* /Data/smb/Torrents/
    #   sudo mv /Data/smb/Media/Movies/* /Data/smb/Torrents/
    #   sudo rmdir /Data/smb/Media/"TV Shows" /Data/smb/Media/Movies
    "d \"/Data/smb/Media/TV Shows\"                   02755 sonarr      media -"
    "d /Data/smb/Media/Movies                         02755 radarr      media -"
    "d /Data/smb/Media/Music                          02755 lidarr      media -"
    "d /Data/smb/Media/Books                          0755 calibre-web  calibre-web -"
    "d /Data/smb/Internal/Services/calibre-web        0700 calibre-web  calibre-web -"
    # Container runs as PUID=987 (calibre-web) so library file ownership
    # stays consistent across both services.
    "d /Data/smb/Internal/Services/calibre-desktop    0750 calibre-web  calibre-web -"
  ];
}
