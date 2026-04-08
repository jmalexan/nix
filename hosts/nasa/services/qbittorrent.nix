{ lib, ... }: {
  services.qbittorrent = {
    enable = true;
    profileDir = "/Data/smb/Internal/Services/qbittorrent/config";
    openFirewall = true;
  };

  # PrivateUsers remaps UIDs in a user namespace, preventing access to files
  # on the ZFS filesystem.
  systemd.services.qbittorrent.serviceConfig = {
    PrivateUsers = lib.mkForce false;
    ReadWritePaths = [ "/Data/smb/Internal/Services/qbittorrent" ];
  };
}
