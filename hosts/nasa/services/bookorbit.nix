{
  config,
  lib,
  vars,
  ...
}:
let
  docker = "${config.virtualisation.docker.package}/bin/docker";
  network = "bookorbit";
  stateDir = "/Data/smb/Internal/Services/bookorbit";
  publicUrl = "https://bookorbit.${vars.nasa.domain}";
in
{
  # BookOrbit owns only its cache and generated application data during the
  # pilot. It reads the existing Calibre library through group 987 and a
  # read-only bind mount.
  users.users.bookorbit = {
    uid = 985;
    group = "bookorbit";
    isSystemUser = true;
    extraGroups = [ "calibre-web" ];
  };
  users.groups.bookorbit.gid = 985;

  # POSTGRES_PASSWORD, JWT_SECRET, SETUP_BOOTSTRAP_TOKEN, and encryption keys
  # for credentials stored by BookOrbit. Docker reads it without copying the
  # plaintext into the Nix store.
  age.secrets.bookorbit-env.file = ../../../secrets/bookorbit-env.age;

  virtualisation.oci-containers.containers = {
    bookorbit-postgres = {
      # BookOrbit 2.2+ ships PostgreSQL 18 with pgvector. Keep this major pinned:
      # changing it requires a dump into a fresh data directory and restore.
      # renovate: datasource=docker depName=docker.io/pgvector/pgvector versioning=docker
      image = "docker.io/pgvector/pgvector:pg18@sha256:2ba9ca5f2e7daa0f0e7723cba1ee9167bab54efd3640516a44ac1a928dd67e7a";
      autoStart = true;
      environment = {
        POSTGRES_USER = "bookorbit";
        POSTGRES_DB = "bookorbit";
        PGDATA = "/var/lib/postgresql/data/pgdata";
      };
      environmentFiles = [ config.age.secrets.bookorbit-env.path ];
      volumes = [ "${stateDir}/postgres:/var/lib/postgresql/data" ];
      extraOptions = [
        "--network=${network}"
        "--health-cmd=pg_isready -U bookorbit -d bookorbit"
        "--health-interval=10s"
        "--health-timeout=5s"
        "--health-retries=10"
        "--health-start-period=20s"
      ];
    };

    bookorbit = {
      # renovate: datasource=docker depName=ghcr.io/bookorbit/bookorbit
      image = "ghcr.io/bookorbit/bookorbit:2.6.0@sha256:a7fa6d124d99bb5cda302160be0736b67e858f6957153e711edbba19e1b93057";
      autoStart = true;
      dependsOn = [ "bookorbit-postgres" ];
      # Eufy already occupies host port 3000; nginx fronts this private port.
      ports = [ "127.0.0.1:3001:3000" ];
      environment = {
        NODE_ENV = "production";
        PORT = "3000";
        POSTGRES_HOST = "bookorbit-postgres";
        POSTGRES_PORT = "5432";
        POSTGRES_USER = "bookorbit";
        POSTGRES_DB = "bookorbit";
        APP_URL = publicUrl;
        CLIENT_URL = publicUrl;
        PUID = "985";
        # The library is owned by calibre-web. The entrypoint uses this as the
        # process's primary group while UID 985 continues to own /data.
        PGID = "987";
        LIBRARY_BROWSE_ROOT = "/books";
        NODE_MAX_OLD_SPACE_SIZE = "2048";
        LOG_LEVEL = "info";
      };
      environmentFiles = [ config.age.secrets.bookorbit-env.path ];
      volumes = [
        "${stateDir}/data:/data"
        "/Data/smb/Media/Books:/books:ro"
      ];
      extraOptions = [
        "--network=${network}"
        "--init"
        "--read-only"
        "--tmpfs=/tmp:rw,nosuid,nodev"
        "--cap-drop=ALL"
        "--cap-add=CHOWN"
        "--cap-add=DAC_OVERRIDE"
        "--cap-add=FOWNER"
        "--cap-add=SETGID"
        "--cap-add=SETUID"
        "--security-opt=no-new-privileges:true"
        "--stop-timeout=30"
        "--health-cmd=node -e \"const p=process.env.PORT||3000;fetch('http://127.0.0.1:'+p+'/api/v1/health').then(r=>process.exit(r.ok?0:1)).catch(()=>process.exit(1))\""
        "--health-interval=30s"
        "--health-timeout=5s"
        "--health-retries=3"
        "--health-start-period=20s"
      ];
    };
  };

  systemd.services =
    (lib.genAttrs
      [
        "docker-bookorbit"
        "docker-bookorbit-postgres"
      ]
      (_: {
        after = [ "bookorbit-network.service" ];
        requires = [ "bookorbit-network.service" ];
      })
    )
    // {
      bookorbit-network = {
        description = "BookOrbit private container network";
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
