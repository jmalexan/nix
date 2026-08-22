{ pkgs, ... }: {
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
    # Immich's dedicated Postgres and ML model cache (containerised). Created
    # root-owned; the postgres entrypoint chowns its data dir to the image's
    # postgres user on first init.
    "d /Data/smb/Internal/Services/immich-postgres    0700 root        root  -"
    "d /Data/smb/Internal/Services/immich-model-cache 0700 root        root  -"
    "d /Data/smb/Internal/Services/jellyfin           0750 jellyfin    root  -"
    "d /Data/smb/Internal/Services/homeassistant      0750 hass        root  -"
    # Frigate runs as root inside its container. The config/ and media/ subdirs
    # plus the seeded config.yml are created in services/frigate.nix.
    "d /Data/smb/Internal/Services/frigate            0750 root        root  -"
    # ring-mqtt also runs as root in its container. Holds the seeded
    # config.json (created in services/ring-mqtt.nix) and ring-state.json,
    # which contains the Ring account refresh token — hence 0700 rather than
    # the 0750 used for state dirs with nothing sensitive in them.
    "d /Data/smb/Internal/Services/ring-mqtt          0700 root        root  -"
    # Standalone go2rtc for the Nest doorbell. 0700 because its go2rtc.yaml
    # holds the Nest OAuth client secret and refresh token. The config itself
    # is seeded from the unit's preStart in services/go2rtc.nix.
    "d /Data/smb/Internal/Services/go2rtc             0700 root        root  -"
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
    # BookOrbit owns the library while the shared media group preserves direct
    # SMB access. This also prepares the future Requests workflow.
    "d /Data/smb/Media/Books                          02775 bookorbit   media       -"
    "d /Data/smb/Media/Manga                          02775 root        media       -"
    # BookOrbit app state is UID-owned; the official
    # pgvector entrypoint initializes ownership inside the Postgres directory.
    "d /Data/smb/Internal/Services/bookorbit          0750 bookorbit    bookorbit -"
    "d /Data/smb/Internal/Services/bookorbit/data     0750 bookorbit    bookorbit -"
    "d /Data/smb/Internal/Services/bookorbit/postgres 0700 root         root -"
  ];

  # Bazarr's upstream tmpfiles rule cannot safely cross the jmalexan-owned
  # /Data/smb path, while Prowlarr deliberately avoids an upstream rule that can
  # create a root-pool stub when ZFS is absent. Create both only after proving
  # that /Data/smb is the mounted dataset. Their units require this oneshot.
  systemd.services.nasa-service-directories = {
    description = "Create service directories on the mounted Data pool";
    after = [ "zfs-mount.service" ];
    requires = [ "zfs-mount.service" ];
    unitConfig.AssertPathIsMountPoint = "/Data/smb";
    serviceConfig.Type = "oneshot";
    script = ''
      ${pkgs.coreutils}/bin/install -d -m 0700 -o bazarr -g bazarr \
        /Data/smb/Internal/Services/bazarr
      ${pkgs.coreutils}/bin/install -d -m 0700 -o root -g root \
        /Data/smb/Internal/Services/prowlarr
    '';
  };
}
