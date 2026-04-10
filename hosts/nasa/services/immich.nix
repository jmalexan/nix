{ lib, ... }: {
  # Pin UIDs/GIDs so file ownership stays consistent across rebuilds and migrations.
  users.users.immich.uid = 998;
  users.groups.immich.gid = 998;

  # Immich needs superuser to CREATE EXTENSION earthdistance (and cube).
  services.postgresql.ensureUsers = [{
    name = "immich";
    ensureClauses.superuser = true;
  }];

  services.immich = {
    enable = true;
    host = "0.0.0.0";
    mediaLocation = "/Data/smb/Internal/Services/immich";
    openFirewall = true;
  };

  # PrivateUsers/PrivateMounts isolate the service in a user namespace, which
  # prevents access to files owned by the immich UID on the ZFS filesystem.
  systemd.services.immich-server.serviceConfig = {
    PrivateUsers = lib.mkForce false;
    PrivateMounts = lib.mkForce false;
    ReadWritePaths = [ "/Data/smb/Internal/Services/immich" ];
  };
}
