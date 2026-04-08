# Machine-specific configuration for "nasa" (bare-metal NixOS host).
# Replace hardware-configuration.nix with the output of nixos-generate-config
# after booting the NixOS installer on this machine.
{ ... }: {
  imports = [
    ./hardware-configuration.nix
    ./services/jellyfin.nix
    ./services/homeassistant.nix
    ./services/qbittorrent.nix
    ./services/immich.nix
    ./services/ddns.nix
    ./services/nginx.nix
    ./services/tailscale.nix
    ./permissions.nix
  ];

  boot.supportedFilesystems = [ "zfs" ];
  boot.zfs.forceImportRoot = false;
  boot.zfs.extraPools = [ "Data" ];

  networking.hostName = "nasa";
  networking.hostId = "e878c22f";

  # Enable KVM/libvirt so this host can run the NixOS VM (and others).
  virtualisation.libvirtd.enable = true;
  programs.virt-manager.enable = true;

  # Podman backend for oci-containers (immich, ha-postgres, ddns-updater).
  virtualisation.podman = {
    enable = true;
    autoPrune.enable = true;
  };
  virtualisation.oci-containers.backend = "podman";

  # ── Samba ─────────────────────────────────────────────────────────────────
  # SMB file sharing optimised for macOS clients on ZFS.
  #
  # Post-deploy steps (one-time):
  #   1. Set Samba password:       sudo smbpasswd -a jmalexan
  #   2. Efficient ZFS xattrs:     sudo zfs set xattr=sa Data/smb
  #   3. Ensure share dir exists:  sudo mkdir -p /Data/smb && sudo chown jmalexan /Data/smb

  services.samba = {
    enable = true;
    openFirewall = true;  # opens TCP 139,445 and UDP 137,138

    settings = {
      global = {
        # Identity
        workgroup = "WORKGROUP";
        "server string" = "nasa";
        "netbios name" = "nasa";

        # Authentication — no guest access
        "server role" = "standalone server";
        security = "user";
        "map to guest" = "never";

        # macOS / Apple SMB2+ extensions
        # catia:       translates macOS special characters in filenames
        # fruit:       AAPL extensions — resource forks, metadata, Finder integration
        # streams_xattr: persists resource forks as ZFS xattrs (needs xattr=sa on dataset)
        "vfs objects" = "catia fruit streams_xattr";
        "fruit:aapl" = "yes";
        "fruit:metadata" = "stream";
        "fruit:model" = "MacSamba";
        "fruit:veto_appledouble" = "no";
        "fruit:posix_rename" = "yes";
        "fruit:zero_file_id" = "yes";
        "fruit:wipe_intentionally_left_blank_rfork" = "yes";
        "fruit:delete_empty_adfiles" = "yes";
        "ea support" = "yes";

        # Protocol — SMB2 minimum; SMB3 preferred for encryption and performance
        "server min protocol" = "SMB2";
        "server max protocol" = "SMB3";

        # Performance
        "socket options" = "TCP_NODELAY IPTOS_LOWDELAY SO_RCVBUF=131072 SO_SNDBUF=131072";
        "use sendfile" = "yes";
        "aio read size" = "1";   # enable async I/O (ZFS write coalescing benefits from this)
        "aio write size" = "1";
        "read raw" = "yes";
        "write raw" = "yes";
        "getwd cache" = "yes";

        "log level" = "1";
      };

      smb = {
        path = "/Data/smb";
        browseable = "yes";
        "read only" = "no";
        "guest ok" = "no";
        "valid users" = "jmalexan";
        "create mask" = "0664";
        "directory mask" = "0775";
      };
    };
  };

  # Avahi/Bonjour — macOS discovers the share via mDNS without manual IP entry
  services.avahi = {
    enable = true;
    nssmdns4 = true;
    publish = {
      enable = true;
      addresses = true;
      workstation = true;
    };
  };
}
