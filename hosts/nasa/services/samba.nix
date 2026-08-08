{ config, pkgs, ... }: {
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

        # Fixed socket buffers disable Linux TCP window autotuning.
        "socket options" = "TCP_NODELAY";
        "aio read size" = "1";
        "aio write size" = "1";
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

  age.secrets.samba-password = {
    file = ../../../secrets/samba-password.age;
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
