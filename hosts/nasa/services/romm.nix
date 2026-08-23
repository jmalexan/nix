{
  config,
  pkgs,
  vars,
  ...
}:
let
  docker = "${config.virtualisation.docker.package}/bin/docker";
  network = "romm";
  stateDir = "/Data/smb/Internal/Services/romm";
  envFile = "${stateDir}/romm.env";
  providersEnvFile = config.age.secrets.romm-providers.path;
in
{
  # Scan the entire qBittorrent ROM category so additional providers and BIOS
  # torrents work without a Nix change. Keep MAME DATs out of the Console DAT
  # tree; arcade sets need a separate job with an exact merge mode.
  services.rommIgir = {
    enable = true;

    jobs = {
      console-1g1r = {
        inputs = [ "/Data/smb/Torrents/ROMs" ];
        dats = [ "/Data/smb/ROM-DATs/Console/**/*.dat" ];
        bios = false;
        # Verify the initial library build. This can be disabled after the
        # generated links have been inspected successfully.
        verify = true;
        extraArgs = [
          "--single"
          "--prefer-language"
          "EN"
          "--prefer-region"
          "USA,WORLD,EUR,JPN"
          "--prefer-retail"
          "--prefer-good"
          "--prefer-verified"
          "--prefer-revision"
          "newer"
        ];
      };

      console-bios = {
        inputs = [ "/Data/smb/Torrents/ROMs" ];
        dats = [ "/Data/smb/ROM-DATs/Console/**/*.dat" ];
        roms = false;
        verify = true;
      };
    };
  };

  # IGDB, SteamGridDB, and RetroAchievements credentials. The decrypted file
  # is consumed directly by Docker and never copied into the Nix store.
  age.secrets.romm-providers = {
    file = ../../../secrets/romm-providers.age;
    mode = "0400";
  };

  virtualisation.oci-containers.containers = {
    romm-db = {
      # Keep the database major explicit. Changing it requires a supported
      # MariaDB upgrade rather than an ordinary container-image refresh.
      # renovate: datasource=docker depName=docker.io/library/mariadb versioning=docker
      image = "docker.io/library/mariadb:11.8.8@sha256:24e76fcec8c003a0362d0dd53f4806e7e79458d7fdeaf47437760e19496f5a9c";
      autoStart = true;
      environment = {
        MARIADB_DATABASE = "romm";
        MARIADB_USER = "romm";
      };
      environmentFiles = [ envFile ];
      volumes = [ "${stateDir}/mariadb:/var/lib/mysql" ];
      extraOptions = [
        "--network=${network}"
        "--health-cmd=healthcheck.sh --connect --innodb_initialized"
        "--health-interval=10s"
        "--health-timeout=5s"
        "--health-retries=10"
        "--health-start-period=30s"
      ];
    };

    romm = {
      # renovate: datasource=docker depName=docker.io/rommapp/romm versioning=docker
      image = "docker.io/rommapp/romm:5.1.0@sha256:ce9d86ab531e09fede45d00f426e3bf2d1f5dd14846f94d6360d77a92a413028";
      autoStart = true;
      dependsOn = [ "romm-db" ];
      ports = [ "127.0.0.1:8086:8080" ];
      environment = {
        DB_HOST = "romm-db";
        DB_NAME = "romm";
        DB_USER = "romm";
        # Hasheous is the only provider in the selected set that needs no
        # account or API key. Credential-backed providers are loaded from the
        # root-only providers.env file provisioned below.
        HASHEOUS_API_ENABLED = "true";
        ROMM_BASE_URL = "https://romm.${vars.nasa.domain}";
        ROMM_SESSION_SECURE_COOKIE = "true";
        SCAN_WORKERS = "2";
        WEB_SERVER_CONCURRENCY = "3";
        TZ = "America/New_York";
      };
      environmentFiles = [
        envFile
        providersEnvFile
      ];
      volumes = [
        # The surviving SMB directory uses RomM's Structure A layout: it
        # contains sibling roms/ and bios/ directories. Mount their parent as
        # the library so both appear at the paths RomM expects.
        # Keeping it separate from state means rebuilding RomM cannot move or
        # delete the library as part of container lifecycle management.
        "${config.services.rommIgir.libraryPath}:/romm/library"
        "${stateDir}/resources:/romm/resources"
        "${stateDir}/assets:/romm/assets"
        "${stateDir}/redis-data:/redis-data"
        "${stateDir}/config:/romm/config"
      ];
      extraOptions = [
        "--network=${network}"
        "--init"
        "--stop-timeout=30"
        "--health-cmd=curl -fsS http://127.0.0.1:8080/api/heartbeat"
        "--health-interval=30s"
        "--health-timeout=5s"
        "--health-retries=5"
        "--health-start-period=60s"
      ];
    };
  };

  systemd.services = {
    docker-romm-db = {
      after = [
        "romm-network.service"
        "romm-secrets.service"
      ];
      requires = [
        "romm-network.service"
        "romm-secrets.service"
      ];
    };

    docker-romm = {
      after = [
        "romm-network.service"
        "romm-secrets.service"
        "romm-db-ready.service"
      ];
      requires = [
        "romm-network.service"
        "romm-secrets.service"
        "romm-db-ready.service"
      ];
    };

    romm-db-ready = {
      description = "Wait for the RomM database";
      after = [ "docker-romm-db.service" ];
      requires = [ "docker-romm-db.service" ];
      serviceConfig.Type = "oneshot";
      script = ''
        attempt=0
        until [ "$(${docker} inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{end}}' romm-db 2>/dev/null)" = healthy ]; do
          attempt=$((attempt + 1))
          if [ "$attempt" -ge 120 ]; then
            echo "Timed out waiting for the RomM database" >&2
            exit 1
          fi
          ${pkgs.coreutils}/bin/sleep 1
        done
      '';
    };

    romm-network = {
      description = "RomM private container network";
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

    romm-secrets = {
      description = "Provision persistent RomM secrets";
      # Agenix decrypts secrets from the NixOS activation script; it does not
      # provide an agenix.service unit. By the time regular system services
      # start, providersEnvFile already exists under /run/agenix.
      after = [ "zfs-mount.service" ];
      requires = [ "zfs-mount.service" ];
      unitConfig.AssertPathIsMountPoint = "/Data/smb";
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };
      script = ''
        if [ ! -e ${envFile} ]; then
          umask 077
          db_password=$(${pkgs.openssl}/bin/openssl rand -hex 32)
          auth_secret=$(${pkgs.openssl}/bin/openssl rand -hex 32)
          root_password=$(${pkgs.openssl}/bin/openssl rand -hex 32)

          ${pkgs.coreutils}/bin/install -m 0600 /dev/null ${envFile}.new
          {
            printf 'DB_PASSWD=%s\n' "$db_password"
            printf 'MARIADB_PASSWORD=%s\n' "$db_password"
            printf 'MARIADB_ROOT_PASSWORD=%s\n' "$root_password"
            printf 'ROMM_AUTH_SECRET_KEY=%s\n' "$auth_secret"
          } >${envFile}.new
          ${pkgs.coreutils}/bin/mv ${envFile}.new ${envFile}
        fi
      '';
    };
  };
}
