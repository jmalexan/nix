{
  lib,
  config,
  pkgs,
  ...
}:
let
  # Immich's two application images move together and are pinned to an exact
  # patch release — NOT a floating `v3`/`release` tag. Under oci-containers a
  # floating tag never changes the systemd unit, so it would neither auto-update
  # nor stay reproducible. Bump both in lockstep (the server and machine-learning
  # image versions must match). See docs/immich upgrade notes before bumping.
  mediaLocation = "/Data/smb/Internal/Services/immich"; # UPLOAD_LOCATION
  dbDataLocation = "/Data/smb/Internal/Services/immich-postgres"; # DB_DATA_LOCATION
  modelCache = "/Data/smb/Internal/Services/immich-model-cache"; # ML model-cache

  docker = "${config.virtualisation.docker.package}/bin/docker";

  # Keep the database/cache network inaccessible to the public-facing proxy.
  # immich-server is the only container attached to both networks.
  backendNetwork = "immich";
  publicNetwork = "immich-public-edge";
in
{
  # Pin UID/GID so file ownership stays consistent across rebuilds and
  # migrations. The nixpkgs module used to create this user; we still declare it
  # so the immich-server container can run as this UID (below) and the `immich`
  # group referenced in modules/common.nix resolves.
  users.users.immich = {
    uid = 998;
    group = "immich";
    isSystemUser = true;
  };
  users.groups.immich.gid = 998;

  # Shared by the server and postgres containers. The plaintext must contain
  # both `DB_PASSWORD=<value>` and `POSTGRES_PASSWORD=<value>` (same value under
  # both names) so a single file serves both containers.
  age.secrets.immich-db-password.file = ../../../secrets/immich-db-password.age;

  # ── Container network ──────────────────────────────────────────────────────
  # oci-containers doesn't manage docker networks, but the containers must
  # resolve each other by name (DB_HOSTNAME=immich-postgres, REDIS_HOSTNAME=
  # immich-redis). A second bridge contains only immich-server and the read-only
  # public share proxy, so compromising the proxy does not provide network
  # access to Postgres, Redis, or machine learning.
  #
  # Docker and the OCI backend are configured once in containers.nix.

  virtualisation.oci-containers.containers = {
    # Dedicated Postgres with the VectorChord/pgvecto-rs image Immich ships and
    # supports. Replaces the old superuser `immich` role on the host's shared
    # Postgres — the container's `postgres` user is already a superuser, so
    # Immich can CREATE EXTENSION without any host-side grant.
    immich-postgres = {
      # renovate: datasource=docker depName=ghcr.io/immich-app/postgres versioning=loose
      image = "ghcr.io/immich-app/postgres:14-vectorchord0.4.3-pgvectors0.2.0@sha256:bcf63357191b76a916ae5eb93464d65c07511da41e3bf7a8416db519b40b1c23";
      autoStart = true;
      environment = {
        POSTGRES_USER = "postgres";
        POSTGRES_DB = "immich";
        POSTGRES_INITDB_ARGS = "--data-checksums";
      };
      environmentFiles = [ config.age.secrets.immich-db-password.path ];
      volumes = [ "${dbDataLocation}:/var/lib/postgresql/data" ];
      extraOptions = [
        "--network=${backendNetwork}"
        "--shm-size=128m"
      ];
    };

    immich-redis = {
      # renovate: datasource=docker depName=docker.io/valkey/valkey
      image = "docker.io/valkey/valkey:9@sha256:4963247afc4cd33c7d3b2d2816b9f7f8eeebab148d29056c2ca4d7cbc966f2d9";
      autoStart = true;
      extraOptions = [ "--network=${backendNetwork}" ];
    };

    immich-machine-learning = {
      # renovate: datasource=docker depName=ghcr.io/immich-app/immich-machine-learning
      image = "ghcr.io/immich-app/immich-machine-learning:v3.1.0";
      autoStart = true;
      volumes = [ "${modelCache}:/cache" ];
      extraOptions = [ "--network=${backendNetwork}" ];
    };

    immich-server = {
      # renovate: datasource=docker depName=ghcr.io/immich-app/immich-server
      image = "ghcr.io/immich-app/immich-server:v3.1.0";
      autoStart = true;
      dependsOn = [
        "immich-postgres"
        "immich-redis"
      ];
      # nginx (immich.nasa.jmalexan.com) fronts this, so bind to loopback only —
      # no LAN firewall port needed (the old module's openFirewall is dropped).
      ports = [ "127.0.0.1:2283:2283" ];
      volumes = [
        "${mediaLocation}:/data"
        "/etc/localtime:/etc/localtime:ro"
      ];
      environment = {
        DB_HOSTNAME = "immich-postgres";
        DB_USERNAME = "postgres";
        DB_DATABASE_NAME = "immich";
        REDIS_HOSTNAME = "immich-redis";
        TZ = "America/New_York";
      };
      environmentFiles = [ config.age.secrets.immich-db-password.path ];
      # Run as the pinned immich UID so newly written media keeps `immich`
      # ownership on ZFS (matching the existing files). Upstream runs the server
      # as root; if it refuses to start as non-root, drop this option and
      # one-time `chown -R immich:immich` the media dir instead.
      extraOptions = [
        "--network=${backendNetwork}"
        "--user=998:998"
      ];
    };

    # Read-only public gallery frontend. It deliberately receives no API key,
    # volumes, Docker socket, host networking, or access to the backend network.
    # nginx/public ingress will be added separately after local compatibility
    # with the deployed Immich version has been verified.
    immich-public-proxy = {
      # IPP 2.x is incompatible with Immich 3.x and crashes while reading
      # shared-album assets. Keep this on a 3.x release and pin the amd64 image.
      # renovate: datasource=docker depName=docker.io/alangrainger/immich-public-proxy
      image = "docker.io/alangrainger/immich-public-proxy:3.2.0@sha256:c10298f420b216e666afaf6f99271f36cce3feade1be1ff0930fd8b9d819b854";
      autoStart = true;
      dependsOn = [ "immich-server" ];
      # Port 3000 on the host is already used by eufy-security-ws. Keep the
      # proxy's native container port while assigning it a private host port.
      ports = [ "127.0.0.1:2284:3000" ];
      environment = {
        IMMICH_URL = "http://immich-server:2283";
        PUBLIC_BASE_URL = "https://photos.jmalexan.com";
      };
      extraOptions = [
        "--network=${publicNetwork}"
        "--cap-drop=ALL"
        "--security-opt=no-new-privileges:true"
        "--read-only"
        "--tmpfs=/tmp:rw,noexec,nosuid,nodev,size=64m"
        "--pids-limit=256"
        "--health-cmd=curl -fsS http://127.0.0.1:3000/share/healthcheck"
        "--health-interval=30s"
        "--health-timeout=5s"
        "--health-retries=3"
        "--health-start-period=10s"
      ];
    };
  };

  systemd.services =
    # Backend containers come up only after both bridges exist.
    (lib.genAttrs
      (map (n: "docker-${n}") [
        "immich-postgres"
        "immich-redis"
        "immich-machine-learning"
        "immich-server"
      ])
      (
        unit:
        {
          after = [ "immich-network.service" ];
          requires = [ "immich-network.service" ];
        }
        // lib.optionalAttrs (unit == "docker-immich-server") {
          # Docker accepts only one network at container creation. Attach the
          # server to the public-edge bridge after every start. ExecStartPost can
          # race `docker run` before it has created the container, so wait for the
          # container to exist before inspecting or connecting it.
          postStart = ''
            attempt=0
            until ${docker} container inspect immich-server >/dev/null 2>&1; do
              attempt=$((attempt + 1))
              if [ "$attempt" -ge 300 ]; then
                echo "Timed out waiting for the immich-server container" >&2
                exit 1
              fi
              ${pkgs.coreutils}/bin/sleep 0.1
            done

            if ! ${docker} network inspect ${publicNetwork} \
              --format '{{range .Containers}}{{println .Name}}{{end}}' \
              | ${pkgs.gnugrep}/bin/grep -Fxq immich-server; then
              ${docker} network connect ${publicNetwork} immich-server
            fi
          '';
        }
      )
    )
    // {
      docker-immich-public-proxy = {
        after = [
          "immich-network.service"
          "docker-immich-server.service"
        ];
        requires = [
          "immich-network.service"
          "docker-immich-server.service"
        ];
      };

      immich-network = {
        description = "Immich private container networks";
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
          ${docker} network inspect ${backendNetwork} >/dev/null 2>&1 || \
            ${docker} network create ${backendNetwork}
          ${docker} network inspect ${publicNetwork} >/dev/null 2>&1 || \
            ${docker} network create ${publicNetwork}
        '';
      };
    };
}
