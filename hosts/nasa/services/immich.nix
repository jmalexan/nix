{ lib, config, ... }:
let
  # Immich's two application images move together and are pinned to an exact
  # patch release — NOT a floating `v3`/`release` tag. Under oci-containers a
  # floating tag never changes the systemd unit, so it would neither auto-update
  # nor stay reproducible. Bump both in lockstep (the server and machine-learning
  # image versions must match). See docs/immich upgrade notes before bumping.
  immichVersion  = "v3.0.1";

  mediaLocation  = "/Data/smb/Internal/Services/immich";              # UPLOAD_LOCATION
  dbDataLocation = "/Data/smb/Internal/Services/immich-postgres";     # DB_DATA_LOCATION
  modelCache     = "/Data/smb/Internal/Services/immich-model-cache";  # ML model-cache

  docker = "${config.virtualisation.docker.package}/bin/docker";
in {
  # Pin UID/GID so file ownership stays consistent across rebuilds and
  # migrations. The nixpkgs module used to create this user; we still declare it
  # so the immich-server container can run as this UID (below) and the `immich`
  # group referenced in modules/common.nix resolves.
  users.users.immich = {
    uid          = 998;
    group        = "immich";
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
  # immich-redis). Create a user-defined bridge once; every container joins it
  # via `--network=immich` below. Mirrors the oneshot pattern in mullvad.nix.
  #
  # docker.enable / oci-containers.backend are set repo-wide in calibre.nix — do
  # NOT redeclare them here (scalar options error if defined twice).

  virtualisation.oci-containers.containers = {
    # Dedicated Postgres with the VectorChord/pgvecto-rs image Immich ships and
    # supports. Replaces the old superuser `immich` role on the host's shared
    # Postgres — the container's `postgres` user is already a superuser, so
    # Immich can CREATE EXTENSION without any host-side grant.
    immich-postgres = {
      image = "ghcr.io/immich-app/postgres:14-vectorchord0.4.3-pgvectors0.2.0@sha256:bcf63357191b76a916ae5eb93464d65c07511da41e3bf7a8416db519b40b1c23";
      autoStart = true;
      environment = {
        POSTGRES_USER        = "postgres";
        POSTGRES_DB          = "immich";
        POSTGRES_INITDB_ARGS = "--data-checksums";
      };
      environmentFiles = [ config.age.secrets.immich-db-password.path ];
      volumes = [ "${dbDataLocation}:/var/lib/postgresql/data" ];
      extraOptions = [ "--network=immich" "--shm-size=128m" ];
    };

    immich-redis = {
      image = "docker.io/valkey/valkey:9@sha256:4963247afc4cd33c7d3b2d2816b9f7f8eeebab148d29056c2ca4d7cbc966f2d9";
      autoStart = true;
      extraOptions = [ "--network=immich" ];
    };

    immich-machine-learning = {
      image = "ghcr.io/immich-app/immich-machine-learning:${immichVersion}";
      autoStart = true;
      volumes = [ "${modelCache}:/cache" ];
      extraOptions = [ "--network=immich" ];
    };

    immich-server = {
      image = "ghcr.io/immich-app/immich-server:${immichVersion}";
      autoStart = true;
      dependsOn = [ "immich-postgres" "immich-redis" ];
      # nginx (immich.nasa.jmalexan.com) fronts this, so bind to loopback only —
      # no LAN firewall port needed (the old module's openFirewall is dropped).
      ports = [ "127.0.0.1:2283:2283" ];
      volumes = [
        "${mediaLocation}:/data"
        "/etc/localtime:/etc/localtime:ro"
      ];
      environment = {
        DB_HOSTNAME      = "immich-postgres";
        DB_USERNAME      = "postgres";
        DB_DATABASE_NAME = "immich";
        REDIS_HOSTNAME   = "immich-redis";
        TZ               = "America/New_York";
      };
      environmentFiles = [ config.age.secrets.immich-db-password.path ];
      # Run as the pinned immich UID so newly written media keeps `immich`
      # ownership on ZFS (matching the existing files). Upstream runs the server
      # as root; if it refuses to start as non-root, drop this option and
      # one-time `chown -R immich:immich` the media dir instead.
      extraOptions = [ "--network=immich" "--user=998:998" ];
    };
  };

  systemd.services =
    # Every container comes up only after the shared network exists.
    (lib.genAttrs
      (map (n: "docker-${n}")
        [ "immich-postgres" "immich-redis" "immich-machine-learning" "immich-server" ])
      (_: {
        after    = [ "immich-network.service" ];
        requires = [ "immich-network.service" ];
      }))
    // {
      immich-network = {
        description = "Immich container network";
        after    = [ "docker.service" "docker.socket" ];
        requires = [ "docker.service" ];
        wantedBy = [ "multi-user.target" ];
        serviceConfig = {
          Type            = "oneshot";
          RemainAfterExit = true;
        };
        script = ''
          ${docker} network inspect immich >/dev/null 2>&1 || \
            ${docker} network create immich
        '';
      };
    };
}
