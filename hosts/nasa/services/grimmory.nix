{
  config,
  lib,
  vars,
  ...
}:
let
  docker = "${config.virtualisation.docker.package}/bin/docker";
  network = "grimmory";
  stateDir = "/Data/smb/Internal/Services/grimmory";
in
{
  # Stable ownership for Grimmory's application cache, BookDrop, and MariaDB.
  # The supplemental calibre-web group lets the container read libraries whose
  # files are not world-readable; the bind mount remains read-only regardless.
  users.users.grimmory = {
    uid = 986;
    group = "grimmory";
    isSystemUser = true;
    extraGroups = [ "calibre-web" ];
  };
  users.groups.grimmory.gid = 986;

  # Contains DATABASE_PASSWORD, MYSQL_PASSWORD (the same application
  # password), and MYSQL_ROOT_PASSWORD. Docker consumes it without copying the
  # plaintext into the Nix store.
  age.secrets.grimmory-db-password.file = ../../../secrets/grimmory-db-password.age;

  virtualisation.oci-containers.containers = {
    grimmory-mariadb = {
      # renovate: datasource=docker depName=lscr.io/linuxserver/mariadb versioning=docker
      image = "lscr.io/linuxserver/mariadb:11.4.8@sha256:91de7f701bc7fc3a424b81beafca7a7c6c4c5b7c8be6afd2ae148698695c0b0c";
      autoStart = true;
      environment = {
        PUID = "986";
        PGID = "986";
        TZ = "America/New_York";
        MYSQL_DATABASE = "grimmory";
        MYSQL_USER = "grimmory";
      };
      environmentFiles = [ config.age.secrets.grimmory-db-password.path ];
      volumes = [ "${stateDir}/mariadb:/config" ];
      extraOptions = [
        "--network=${network}"
        "--health-cmd=mariadb-admin ping -h localhost --silent"
        "--health-interval=10s"
        "--health-timeout=5s"
        "--health-retries=10"
        "--health-start-period=30s"
      ];
    };

    grimmory = {
      # Keep the pilot reproducible; review release notes before changing the
      # tag because Grimmory is still moving quickly.
      # renovate: datasource=docker depName=ghcr.io/grimmory-tools/grimmory
      image = "ghcr.io/grimmory-tools/grimmory:v3.3.2@sha256:8a3a046822dee460f3e67df5d548e3b9842057a54ed830026edb20ecc116c8ce";
      autoStart = true;
      dependsOn = [ "grimmory-mariadb" ];
      ports = [ "127.0.0.1:6060:6060" ];
      environment = {
        USER_ID = "986";
        GROUP_ID = "986";
        TZ = "America/New_York";
        SERVER_PORT = "6060";
        DATABASE_URL = "jdbc:mariadb://grimmory-mariadb:3306/grimmory";
        DATABASE_USERNAME = "grimmory";
        # The library is a shared ZFS-backed tree. NETWORK disables Grimmory's
        # move/rename/delete operations; the read-only mount is a second guard.
        DISK_TYPE = "NETWORK";
        API_DOCS_ENABLED = "false";
        ALLOWED_ORIGINS = "https://grimmory.${vars.nasa.domain}";
      };
      environmentFiles = [ config.age.secrets.grimmory-db-password.path ];
      volumes = [
        "${stateDir}/data:/app/data"
        "${stateDir}/bookdrop:/bookdrop"
        "/Data/smb/Media/Books:/books:ro"
      ];
      extraOptions = [
        "--network=${network}"
        "--group-add=987"
        "--health-cmd=wget -q -O - http://127.0.0.1:6060/api/v1/healthcheck >/dev/null"
        "--health-interval=60s"
        "--health-timeout=10s"
        "--health-retries=5"
        "--health-start-period=60s"
      ];
    };
  };

  # A named bridge gives the application private DNS access to MariaDB without
  # publishing the database port on the host.
  systemd.services =
    (lib.genAttrs
      [
        "docker-grimmory"
        "docker-grimmory-mariadb"
      ]
      (_: {
        after = [ "grimmory-network.service" ];
        requires = [ "grimmory-network.service" ];
      })
    )
    // {
      grimmory-network = {
        description = "Grimmory private container network";
        after = [
          "docker.service"
          "docker.socket"
        ];
        requires = [ "docker.service" ];
        wantedBy = [ "multi-user.target" ];
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
        };
        script = ''
          ${docker} network inspect ${network} >/dev/null 2>&1 || \
            ${docker} network create ${network}
        '';
      };
    };
}
