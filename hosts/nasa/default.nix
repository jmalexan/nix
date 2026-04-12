{ lib, pkgs, config, ... }: {
  imports = [
    ./hardware-configuration.nix
    ./permissions.nix
  ] ++ (map (f: ./services/${f})
       (builtins.attrNames
         (lib.filterAttrs (n: v: v == "regular" && lib.hasSuffix ".nix" n)
           (builtins.readDir ./services))));

  boot.supportedFilesystems = [ "zfs" ];
  boot.zfs.forceImportRoot = false;
  boot.zfs.extraPools = [ "Data" ];

  # ZFS ARC limits — host has 32 GiB RAM
  boot.extraModprobeConfig = ''
    options zfs zfs_arc_max=17179869184
    options zfs zfs_arc_min=2147483648
  '';

  networking.hostName = "nasa";
  networking.hostId = "e878c22f";

  # ── Samba ─────────────────────────────────────────────────────────────────
  # SMB file sharing optimised for macOS clients on ZFS.

  services.samba = {
    enable = true;
    openFirewall = true;

    settings = {
      global = {
        workgroup = "WORKGROUP";
        "server string" = "nasa";
        "netbios name" = "nasa";

        "server role" = "standalone server";
        security = "user";
        "map to guest" = "never";

        # macOS / Apple SMB2+ extensions
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

        "server min protocol" = "SMB2";
        "server max protocol" = "SMB3";

        "socket options" = "TCP_NODELAY IPTOS_LOWDELAY SO_RCVBUF=131072 SO_SNDBUF=131072";
        "use sendfile" = "yes";
        "aio read size" = "1";
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

  age.identityPaths = [ "/etc/age/host.key" ];

  age.secrets.samba-password = {
    file = ../../secrets/samba-password.age;
    mode = "0400";
  };

  system.activationScripts.sambaPasswords = {
    deps = [ "agenix" ];
    text = ''
      pw=$(cat ${config.age.secrets.samba-password.path})
      printf '%s\n%s\n' "$pw" "$pw" | ${pkgs.samba}/bin/smbpasswd -s -a jmalexan || \
      printf '%s\n%s\n' "$pw" "$pw" | ${pkgs.samba}/bin/smbpasswd -s jmalexan
    '';
  };

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
