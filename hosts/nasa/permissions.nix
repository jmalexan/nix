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

  systemd.tmpfiles.rules = [
    "d /Data/smb                                      0755 jmalexan    root -"
    "d /Data/smb/Internal                             0755 root        root -"
    "d /Data/smb/Internal/Services                    0755 root        root -"
    "d /Data/smb/Internal/Services/immich             0750 immich      root -"
    "d /Data/smb/Internal/Services/jellyfin           0750 jellyfin    root -"
    "d /Data/smb/Internal/Services/homeassistant      0750 hass        root -"
    "d /Data/smb/Internal/Services/qbittorrent        0750 qbittorrent root -"
    "d /Data/smb/Media                                0755 root        root -"
    "d /Data/smb/Torrents                             0750 qbittorrent qbittorrent -"
  ];
}
