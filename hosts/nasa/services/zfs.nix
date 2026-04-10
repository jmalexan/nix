{ ... }: {
  # ── One-time dataset setup ─────────────────────────────────────────────────
  #
  # Enable POSIX ACLs so setfacl default entries are honoured on new files:
  #   sudo zfs set acltype=posixacl Data/smb
  #
  # Store xattrs in the dnode (faster Samba resource fork I/O):
  #   sudo zfs set xattr=sa Data/smb

  services.zfs.autoScrub = {
    enable = true;
    interval = "monthly";
  };

  services.zfs.autoSnapshot = {
    enable = true;
    frequent = 4;   # every 15 min, keep 4
    hourly   = 24;
    daily    = 14;
    weekly   = 8;
    monthly  = 12;
  };
}
