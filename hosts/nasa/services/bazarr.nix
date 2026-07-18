{ ... }: {
  # Add to the media group so Bazarr can read /Data/smb/Torrents and write
  # subtitle files alongside the videos in /Data/smb/Media (both owned by or
  # group-accessible via media).
  users.users.bazarr.extraGroups = [ "media" ];

  services.bazarr = {
    enable = true;
    # The bazarr module emits a systemd-tmpfiles rule to create this dir, but
    # tmpfiles refuses with "unsafe path transition" because /Data/smb is owned
    # by jmalexan while /Data/smb/Internal is root-owned.  Like the other *arr
    # service dirs, bootstrap it once by hand (persists on ZFS across rebuilds):
    #   sudo install -d -o bazarr -g bazarr -m 0700 /Data/smb/Internal/Services/bazarr
    dataDir = "/Data/smb/Internal/Services/bazarr";
    openFirewall = false;
  };

  # Route all outbound traffic through the Mullvad VPN namespace (the same one
  # qbittorrent uses) so subtitle-provider queries never traverse the ISP link.
  # nginx reaches the web UI via the veth at 10.200.200.2:6767.  Inter-app
  # comms (Sonarr, Radarr) stay on localhost since they share this netns.
  systemd.services.bazarr = {
    after    = [ "mullvad-netns.service" ];
    requires = [ "mullvad-netns.service" ];
    serviceConfig.NetworkNamespacePath = "/run/netns/mullvad";
  };
}
