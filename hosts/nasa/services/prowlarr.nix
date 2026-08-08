{ vars, ... }: {
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
  systemd.mounts = [
    {
      what = "/Data/smb/Internal/Services/prowlarr";
      where = "/var/lib/private/prowlarr";
      type = "none";
      options = "bind";

      after = [
        "zfs-mount.service"
        "nasa-service-directories.service"
      ];
      requires = [
        "zfs-mount.service"
        "nasa-service-directories.service"
      ];
      wantedBy = [ "local-fs.target" ];

      # Belt and braces: `zfs mount -a` exits 0 when the pool was never imported,
      # so success of zfs-mount.service alone does not prove /Data/smb is there.
      unitConfig.AssertPathIsMountPoint = "/Data/smb";
    }
  ];

  # ── Deliberately NOT in the Mullvad namespace ─────────────────────────────
  #
  # Prowlarr used to run inside the netns to keep indexer queries off the ISP
  # link.  It has to leave for the same reason FlareSolverr did, but the
  # mechanism is subtler: Cloudflare binds the cf_clearance cookie to the IP
  # that solved the challenge.  With FlareSolverr on the host and Prowlarr in
  # the tunnel, the challenge was solved from the ISP address and then replayed
  # from the Mullvad exit — Cloudflare saw the clearance presented by a
  # different IP and rejected it, which surfaces as "Cloudflare protection
  # detected" even though FlareSolverr logged a clean solve.
  #
  # Whatever obtains the clearance and whatever uses it must share an egress
  # address.  Both in the tunnel means challenges never solve at all, so the
  # only working arrangement is both on the host.
  #
  # Torrent traffic is unaffected: qbittorrent is the only thing here that
  # joins a swarm and it stays namespaced (see qbittorrent.nix).  Prowlarr only
  # makes HTTPS requests to indexer web servers.
  systemd.services.prowlarr = {
    # Still ordered after mullvad-netns despite leaving the namespace: the
    # bind address below is the host end of that unit's veth pair, so it does
    # not exist until the unit has run.  partOf as well, because a netns
    # restart recreates veth-host and would strand the listening socket.
    after = [
      "mullvad-netns.service"
      "var-lib-private-prowlarr.mount"
    ];
    requires = [
      "mullvad-netns.service"
      "var-lib-private-prowlarr.mount"
    ];
    partOf = [ "mullvad-netns.service" ];
    # Refuse to start on a data dir that is not the one on the pool.
    unitConfig.AssertPathIsMountPoint = "/var/lib/private/prowlarr";
  };

  # Bound to the host end of the veth pair rather than the "*" the servarr
  # default uses.  br0 is in networking.firewall.trustedInterfaces, so a
  # wildcard bind would publish the web UI to every device on the LAN and the
  # firewall would not stop it.  10.200.200.1 is reachable from this host (for
  # nginx) and from inside the namespace (for the *arr apps), which is exactly
  # the set of clients that need it.  (Address is hostVethIP in mullvad.nix.)
  services.prowlarr.settings.server.bindaddress = vars.nasa.hostVethIP;

  # sonarr/radarr/lidarr/bazarr are still namespaced and no longer share a
  # localhost with Prowlarr.  They normally reach it through nginx via
  # prowlarr.nasa.jmalexan.com over the LAN bypass, which needs no rule here —
  # but opening 9696 on the veth keeps the direct 10.200.200.1:9696 path
  # working too, whichever way they happen to be configured.  Scoped to
  # veth-host, so this does not expose Prowlarr on br0.
  networking.firewall.interfaces.veth-host.allowedTCPPorts = [ 9696 ];
}
