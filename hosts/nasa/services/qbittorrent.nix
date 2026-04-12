{ lib, ... }: {
  # Pin UIDs/GIDs so file ownership stays consistent across rebuilds and migrations.
  users.users.qbittorrent.uid = 994;
  users.groups.qbittorrent.gid = 994;

  services.qbittorrent = {
    enable = true;
    profileDir = "/Data/smb/Internal/Services/qbittorrent/config";
    # Port forwarding is handled by Mullvad, not the host firewall.
    openFirewall = false;
  };

  # PrivateUsers remaps UIDs in a user namespace, preventing access to files
  # on the ZFS filesystem.
  systemd.services.qbittorrent = {
    # Require the Mullvad VPN namespace to be ready first.
    after    = [ "mullvad-netns.service" ];
    requires = [ "mullvad-netns.service" ];
    serviceConfig = {
      PrivateUsers         = lib.mkForce false;
      ReadWritePaths       = [ "/Data/smb/Internal/Services/qbittorrent" "/Data/smb/Torrents" ];
      # Run inside the Mullvad network namespace — all traffic exits via VPN.
      NetworkNamespacePath = "/run/netns/mullvad";
      # Create files as 664 (group-writable) so the *arr services can create
      # hardlinks to downloaded files without tripping fs.protected_hardlinks.
      UMask                = "0002";
    };
  };
}
