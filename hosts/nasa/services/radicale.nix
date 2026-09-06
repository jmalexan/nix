{ config, pkgs, ... }:

let
  dataDir = "/Data/smb/Internal/Services/radicale/collections";
  credentialsDir = "/run/radicale-credentials";
  usersFile = "${credentialsDir}/users";
in
{
  # Radicale provides CalDAV calendars and CardDAV address books. It only
  # listens on loopback; nginx is the TLS-terminating client entry point.
  services.radicale = {
    enable = true;
    settings = {
      server.hosts = [ "127.0.0.1:5232" ];
      auth = {
        type = "htpasswd";
        htpasswd_filename = usersFile;
        htpasswd_encryption = "bcrypt";
      };
      storage.filesystem_folder = dataDir;
    };

    # Each authenticated user can see and manage only their own principal and
    # collections. These are Radicale's documented owner-only rights.
    rights = {
      root = {
        user = ".+";
        collection = "";
        permissions = "R";
      };
      principal = {
        user = ".+";
        collection = "{user}";
        permissions = "RW";
      };
      calendars = {
        user = ".+";
        collection = "{user}/[^/]+";
        permissions = "rw";
      };
    };
  };

  # Keep the existing personal login while avoiding a second independently
  # managed password: derive Radicale's bcrypt htpasswd file at boot from the
  # encrypted Samba password. The plaintext never enters the Nix store.
  systemd.services.radicale-credentials = {
    description = "Generate Radicale credentials";
    before = [ "radicale.service" ];
    # Re-run during a switch when the encrypted source password changes.
    restartTriggers = [ config.age.secrets.samba-password.file ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      User = "root";
      Group = "radicale";
      RuntimeDirectory = "radicale-credentials";
      RuntimeDirectoryMode = "0750";
      UMask = "0027";
    };
    script = ''
      set -euo pipefail

      password=$(${pkgs.coreutils}/bin/cat ${config.age.secrets.samba-password.path})
      users_tmp=$(${pkgs.coreutils}/bin/mktemp ${credentialsDir}/.users.XXXXXX)
      cleanup() {
        ${pkgs.coreutils}/bin/rm -f "$users_tmp"
      }
      trap cleanup EXIT

      ${pkgs.coreutils}/bin/printf '%s\n' "$password" \
        | ${pkgs.apacheHttpd}/bin/htpasswd -niB jmalexan > "$users_tmp"
      ${pkgs.coreutils}/bin/chown root:radicale "$users_tmp"
      ${pkgs.coreutils}/bin/chmod 0640 "$users_tmp"
      ${pkgs.coreutils}/bin/mv "$users_tmp" ${usersFile}
      trap - EXIT
    '';
  };

  # Refuse to start unless the ZFS-backed state directory and runtime
  # credentials have both been prepared successfully.
  systemd.services.radicale = {
    after = [
      "nasa-service-directories.service"
      "radicale-credentials.service"
    ];
    requires = [
      "nasa-service-directories.service"
      "radicale-credentials.service"
    ];
    unitConfig.AssertPathIsMountPoint = "/Data/smb";
  };
}
