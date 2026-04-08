{ ... }: {
  # users (gid 100, pre-existing) — service config dirs are group-owned by
  #   `users` so jmalexan has full rwx. Added to jmalexan's extraGroups in
  #   configuration.nix.
  #
  # media — shared group for services that read/write media files.
  #   jmalexan is also a member (via extraGroups in configuration.nix).

  users.groups.media.members = [ "immich" "jellyfin" "qbittorrent" ];

  # systemd-tmpfiles enforces mode/ownership on every boot. `d` creates the
  # directory if missing; only affects the named directory, never recurses.
  systemd.tmpfiles.rules = [
    # Traversal — world-executable so service users can reach their subdirs
    "d /Data/smb                                0755 jmalexan    users -"
    "d /Data/smb/Internal                       0755 root        root  -"
    "d /Data/smb/Internal/Services              0755 root        root  -"

    # Service dirs — owned by each service, group=users so jmalexan has rwx
    "d /Data/smb/Internal/Services/immich         0770 immich       users -"
    "d /Data/smb/Internal/Services/jellyfin       0770 jellyfin     users -"
    "d /Data/smb/Internal/Services/homeassistant  0770 hass         users -"
    "d /Data/smb/Internal/Services/qbittorrent    0770 qbittorrent  users -"

    # Shared media — setgid so new files/dirs inherit the media group
    "d /Data/smb/Media                          2775 root        media -"
  ];
}
