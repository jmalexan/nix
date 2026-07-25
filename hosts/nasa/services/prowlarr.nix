{ ... }: {
  # Prowlarr is an indexer manager — it routes searches between the *arr apps
  # and your torrent indexers.  It doesn't touch media files, so it needs no
  # access to /Data/smb and runs fine with systemd's DynamicUser isolation.
  #
  # NOTE: `dataDir` is deliberately left at its default.  See below — we declare
  # the bind mount that backs it ourselves so it can be made safe.
  services.prowlarr = {
    enable = true;
    openFirewall = false;
  };

  # ── Persistent data lives on the ZFS pool, safely ──────────────────────────
  #
  # Unlike sonarr/radarr/lidarr, the upstream Prowlarr module does NOT pass
  # `dataDir` to the binary.  Prowlarr is always launched with
  # `-data=/var/lib/prowlarr` under DynamicUser + StateDirectory, and setting
  # `dataDir` merely makes the module bind-mount that directory onto
  # /var/lib/private/prowlarr.  Upstream wires it up with two holes:
  #
  #   * the .mount unit gets `wantedBy = [ "local-fs.target" ]` and an otherwise
  #     empty [Unit] section, so it neither waits for the ZFS `Data` pool nor
  #     blocks prowlarr.service, which has no dependency on it at all; and
  #   * a tmpfiles rule *creates* the data dir (0700 root:root) if it is missing.
  #
  # So on a boot where zfs-import-Data fails or lands late — it retries
  # `zpool import` for 60s and then gives up — tmpfiles creates an empty stub
  # directory at that path on the *root* pool, the bind mount happily binds the
  # stub, and Prowlarr initialises a brand-new database.  ZFS later mounts
  # Data/smb over /Data/smb, hiding both the stub and the real data, and nothing
  # anywhere logs an error.  That is how every indexer disappeared on the
  # 2026-07-24 cold boot after the move.
  #
  # Declaring the mount here instead means there is no tmpfiles rule to
  # conjure a stub, the bind waits on (and requires) the ZFS mount, and
  # prowlarr.service requires the bind.  Any failure now leaves Prowlarr down
  # and loud in the journal rather than quietly serving a blank config.
  systemd.mounts = [{
    what  = "/Data/smb/Internal/Services/prowlarr";
    where = "/var/lib/private/prowlarr";
    type  = "none";
    options = "bind";

    after    = [ "zfs-mount.service" ];
    requires = [ "zfs-mount.service" ];
    wantedBy = [ "local-fs.target" ];

    # Belt and braces: `zfs mount -a` exits 0 when the pool was never imported,
    # so success of zfs-mount.service alone does not prove /Data/smb is there.
    unitConfig.AssertPathIsMountPoint = "/Data/smb";
  }];

  # Prowlarr is the app that actually queries the torrent indexers/trackers, so
  # route it through the Mullvad VPN namespace (the same one qbittorrent uses)
  # to keep those queries off the ISP link.  nginx reaches the web UI via the
  # veth at 10.200.200.2:9696; the *arr apps reach it on localhost (shared netns).
  systemd.services.prowlarr = {
    after    = [ "mullvad-netns.service" "var-lib-private-prowlarr.mount" ];
    requires = [ "mullvad-netns.service" "var-lib-private-prowlarr.mount" ];
    # Refuse to start on a data dir that is not the one on the pool.
    unitConfig.AssertPathIsMountPoint = "/var/lib/private/prowlarr";
    serviceConfig.NetworkNamespacePath = "/run/netns/mullvad";
  };
}
