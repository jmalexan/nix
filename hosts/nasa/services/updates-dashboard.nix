{
  config,
  lib,
  pkgs,
  pkgs-unstable,
  vars,
  ...
}:
let
  docker = "${config.virtualisation.docker.package}/bin/docker";
  network = "updates-dashboard";
  stateDir = "${vars.nasa.serviceRoot}/updates-dashboard";
  databaseEnv = "${stateDir}/postgres.env";
  apiEnv = "${stateDir}/api.env";
  repositoryUrl = "https://github.com/${lib.removePrefix "github:" vars.repository}.git";

  # Udash requires a config file even when every deploy-specific value comes
  # from the environment. Keep the database URI out of the Nix store: its key
  # is deliberately absent here so UDASH_DB_URI from apiEnv remains the
  # fallback. nginx limits this unauthenticated trial to trusted networks.
  apiConfig = pkgs.writeText "udash-config.yaml" ''
    server:
      auth:
        mode: "none"
  '';

  frontendConfig = pkgs.writeText "udash-config.json" (
    builtins.toJSON {
      AUTH_ENABLED = false;
      AUTH_VISIBILITY = "private";
      OAUTH_DOMAIN = "";
      OAUTH_CLIENTID = "";
      OAUTH_SCOPE = "";
      API_BASE_URL = "/api";
      APP_BASE_PATH = "/";
      MAX_HISTORY_DAYS = 90;
    }
  );

  scm = {
    repository = {
      kind = "git";
      spec = {
        url = repositoryUrl;
        branch = "main";
        depth = 1;
        singlebranch = true;
      };
    };
  };

  parseImage =
    image:
    let
      taggedImage = builtins.head (lib.splitString "@" image);
      digestParts = lib.splitString "@" image;
      tagMatch = builtins.match "^(.*):([^:]*)$" taggedImage;
    in
    {
      repository = builtins.elemAt tagMatch 0;
      tag = builtins.elemAt tagMatch 1;
      digest = if builtins.length digestParts == 2 then builtins.elemAt digestParts 1 else "";
    };

  # Preserve compatibility channels for stateful databases and hardware image
  # variants. Everything else follows the newest semantic release.
  versionFilter =
    name:
    {
      bookorbit-postgres = {
        kind = "regex";
        pattern = "^pg18$";
      };
      frigate = {
        kind = "regex";
        pattern = "^[0-9]+\\.[0-9]+\\.[0-9]+-tensorrt$";
      };
      immich-postgres = {
        kind = "regex";
        pattern = "^14-vectorchord[0-9]+\\.[0-9]+\\.[0-9]+-pgvector[0-9]+\\.[0-9]+\\.[0-9]+$";
      };
      immich-redis = {
        kind = "regex";
        pattern = "^9$";
      };
      music-assistant = {
        kind = "regex";
        pattern = "^[0-9]+\\.[0-9]+\\.[0-9]+$";
      };
      updates-dashboard-postgres = {
        kind = "semver";
        pattern = "~17";
      };
    }
    .${name} or {
      kind = "semver";
    };

  containerImages = lib.mapAttrs (
    _: container: parseImage container.image
  ) config.virtualisation.oci-containers.containers;

  compareCandidate = pkgs.writeShellApplication {
    name = "compare-update-candidate";
    text = ''
      current="''${1:?current value is required}"
      candidate="''${2:?candidate value is required}"

      if [ "$current" != "$candidate" ]; then
        printf '%s -> %s\n' "$current" "$candidate"
      fi
    '';
  };

  # Updatecli's dockerdigest source resolves some multi-platform images to an
  # amd64 child manifest, while Renovate and Docker pin the image index. Skopeo
  # reports the index digest consistently, avoiding permanent false alerts.
  registryDigest = pkgs.writeShellApplication {
    name = "registry-index-digest";
    runtimeInputs = [ pkgs.skopeo ];
    text = ''
      repository="''${1:?image repository is required}"
      tag="''${2:?image tag is required}"
      digest=$(skopeo inspect --format "{{.Digest}}" "docker://$repository:$tag")
      printf '%s@%s\n' "$tag" "$digest"
    '';
  };

  releaseSources = lib.mapAttrs (name: image: {
    name = "${name} (installed: ${image.tag})";
    kind = "dockerimage";
    scmid = "repository";
    spec = {
      image = image.repository;
      versionfilter = versionFilter name;
    };
  }) containerImages;

  releaseTargets = lib.mapAttrs (name: image: {
    name = "${name}: compare installed tag ${image.tag}";
    kind = "shell";
    sourceid = name;
    spec.command = "${compareCandidate}/bin/compare-update-candidate ${image.tag}";
  }) containerImages;

  digestSources = lib.mapAttrs (name: image: {
    name = "${name} (pinned: ${image.tag}@${image.digest})";
    kind = "shell";
    scmid = "repository";
    spec.command = "${registryDigest}/bin/registry-index-digest ${image.repository} ${image.tag}";
  }) containerImages;

  digestTargets = lib.mapAttrs (name: image: {
    name = "${name}: compare pinned digest";
    kind = "shell";
    sourceid = name;
    spec.command = "${compareCandidate}/bin/compare-update-candidate ${image.tag}@${image.digest}";
  }) containerImages;

  releaseInventory = pkgs.writeText "updatecli-oci-releases.json" (
    builtins.toJSON {
      name = "OCI release forecast";
      labels = {
        category = "oci";
        forecast = "release";
      };
      scms = scm;
      sources = releaseSources;
      targets = releaseTargets;
    }
  );

  digestInventory = pkgs.writeText "updatecli-oci-digests.json" (
    builtins.toJSON {
      name = "OCI pinned digest drift";
      labels = {
        category = "oci";
        forecast = "digest";
      };
      scms = scm;
      sources = digestSources;
      targets = digestTargets;
    }
  );

  nixUpdateForecast = pkgs.writeShellApplication {
    name = "nix-update-forecast";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.nix
    ];
    text = ''
      mode="''${1:-forecast}"
      source_dir="$PWD"
      candidate_root=$(mktemp -d -t nix-update-forecast.XXXXXX)
      candidate_dir="$candidate_root/repository"
      cleanup() {
        rm -rf "$candidate_root"
      }
      trap cleanup EXIT

      cp -a "$source_dir" "$candidate_dir"
      chmod -R u+w "$candidate_dir"
      nix flake update --flake "path:$candidate_dir"

      if cmp -s "$source_dir/flake.lock" "$candidate_dir/flake.lock"; then
        if [ "$mode" = forecast ]; then
          printf 'flake.lock is current; no Nix package changes are forecast.\n'
        fi
        exit 0
      fi

      if [ "$mode" = status ]; then
        printf 'flake.lock has newer inputs available\n'
        exit 0
      fi

      printf 'Updating flake.lock now would produce these closure changes:\n'
      for host in nasa htpc; do
        printf '\n[%s]\n' "$host"
        current=$(nix build --no-link --print-out-paths \
          "path:$source_dir#nixosConfigurations.$host.config.system.build.toplevel")
        candidate=$(nix build --no-link --print-out-paths \
          "path:$candidate_dir#nixosConfigurations.$host.config.system.build.toplevel")
        nix store diff-closures "$current" "$candidate"
      done
    '';
  };

  nixInventory = pkgs.writeText "updatecli-nix-forecast.json" (
    builtins.toJSON {
      name = "Nix flake update forecast";
      labels = {
        category = "nix";
        forecast = "closure";
      };
      scms = scm;
      sources.forecast = {
        name = "Package versions after updating flake.lock";
        kind = "shell";
        scmid = "repository";
        spec.command = "${nixUpdateForecast}/bin/nix-update-forecast";
      };
      targets.update-available = {
        name = "Whether flake.lock has newer inputs";
        kind = "shell";
        scmid = "repository";
        disablesourceinput = true;
        spec.command = "${nixUpdateForecast}/bin/nix-update-forecast status";
      };
    }
  );

  reportService = configFile: {
    after = [
      "network-online.target"
      "updates-dashboard-api-ready.service"
    ];
    wants = [ "network-online.target" ];
    requires = [ "updates-dashboard-api-ready.service" ];
    environment = {
      HOME = "/var/lib/updates-dashboard-reporter";
      UPDATECLI_UDASH_API_URL = "http://127.0.0.1:8090/api";
      UPDATECLI_UDASH_URL = "https://updates.${vars.nasa.domain}";
    };
    serviceConfig = {
      Type = "oneshot";
      User = "updates-dashboard-reporter";
      Group = "updates-dashboard-reporter";
      StateDirectory = "updates-dashboard-reporter";
      CacheDirectory = "updates-dashboard-reporter";
      PrivateTmp = true;
      NoNewPrivileges = true;
      Nice = 10;
      IOSchedulingClass = "idle";
    };
    script = ''
      ${pkgs-unstable.updatecli}/bin/updatecli pipeline diff \
        --experimental \
        --config ${configFile}
    '';
  };
in
{
  users.users.updates-dashboard-reporter = {
    isSystemUser = true;
    group = "updates-dashboard-reporter";
    home = "/var/lib/updates-dashboard-reporter";
  };
  users.groups.updates-dashboard-reporter = { };

  virtualisation.oci-containers.containers = {
    updates-dashboard-postgres = {
      # PostgreSQL stays on major 17; patch releases and republished images are
      # surfaced by this dashboard before the declaration changes.
      # renovate: datasource=docker depName=docker.io/library/postgres versioning=docker
      image = "docker.io/library/postgres:17.11@sha256:67f41722b7a8cbdb868a44a4995c846eddfdc2973bccb291ce937dce88ad5675";
      autoStart = true;
      environment = {
        POSTGRES_USER = "udash";
        POSTGRES_DB = "udash";
        PGDATA = "/var/lib/postgresql/data/pgdata";
      };
      environmentFiles = [ databaseEnv ];
      volumes = [ "${stateDir}/postgres:/var/lib/postgresql/data" ];
      extraOptions = [
        "--network=${network}"
        "--health-cmd=pg_isready -U udash -d udash"
        "--health-interval=10s"
        "--health-timeout=5s"
        "--health-retries=12"
        "--health-start-period=20s"
      ];
    };

    updates-dashboard-api = {
      # renovate: datasource=docker depName=ghcr.io/updatecli/udash versioning=docker
      image = "ghcr.io/updatecli/udash:v0.17.1@sha256:76450ac9e81edfd705b02dc66bd66b226e6620a3cb4bd0488c4dd9a461266e4c";
      autoStart = true;
      dependsOn = [ "updates-dashboard-postgres" ];
      cmd = [
        "server"
        "start"
      ];
      ports = [ "127.0.0.1:8090:8080" ];
      environment = {
        GIN_MODE = "release";
        # Udash has no built-in local-password mode. The nginx vhost is limited
        # to LAN and Tailscale clients while this trial runs without OIDC.
        UDASH_AUTH_MODE = "none";
      };
      environmentFiles = [ apiEnv ];
      volumes = [ "${apiConfig}:/home/udash/config.yaml:ro" ];
      extraOptions = [
        "--network=${network}"
        "--read-only"
        "--tmpfs=/tmp:rw,nosuid,nodev"
        "--tmpfs=/home/udash/.udash:rw,nosuid,nodev,uid=1000,gid=1000"
        "--cap-drop=ALL"
        "--security-opt=no-new-privileges:true"
        "--health-cmd=curl -fsS http://127.0.0.1:8080/api/ping"
        "--health-interval=30s"
        "--health-timeout=5s"
        "--health-retries=5"
        "--health-start-period=20s"
      ];
    };

    updates-dashboard-front = {
      # renovate: datasource=docker depName=ghcr.io/updatecli/udash-front versioning=docker
      image = "ghcr.io/updatecli/udash-front:v0.25.0@sha256:1b4977cc534b643a61fadfd8da27ef771e95b55af1ada038e1086a165205552d";
      autoStart = true;
      dependsOn = [ "updates-dashboard-api" ];
      ports = [ "127.0.0.1:8091:80" ];
      volumes = [ "${frontendConfig}:/usr/share/nginx/html/config.json:ro" ];
      extraOptions = [
        "--network=${network}"
        "--security-opt=no-new-privileges:true"
        "--health-cmd=wget -q -O /dev/null http://127.0.0.1/"
        "--health-interval=30s"
        "--health-timeout=5s"
        "--health-retries=5"
        "--health-start-period=10s"
      ];
    };
  };

  systemd.services = {
    docker-updates-dashboard-postgres = {
      after = [
        "updates-dashboard-network.service"
        "updates-dashboard-secrets.service"
      ];
      requires = [
        "updates-dashboard-network.service"
        "updates-dashboard-secrets.service"
      ];
    };

    docker-updates-dashboard-api = {
      after = [
        "updates-dashboard-network.service"
        "updates-dashboard-secrets.service"
        "updates-dashboard-database-ready.service"
      ];
      requires = [
        "updates-dashboard-network.service"
        "updates-dashboard-secrets.service"
        "updates-dashboard-database-ready.service"
      ];
    };

    docker-updates-dashboard-front = {
      after = [ "updates-dashboard-api-ready.service" ];
      requires = [ "updates-dashboard-api-ready.service" ];
    };

    updates-dashboard-network = {
      description = "Udash private container network";
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

    updates-dashboard-secrets = {
      description = "Provision the Udash database credential";
      after = [ "zfs-mount.service" ];
      requires = [ "zfs-mount.service" ];
      unitConfig.AssertPathIsMountPoint = "/Data/smb";
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };
      script = ''
        set -euo pipefail

        password_file=${stateDir}/database-password
        if [ ! -s "$password_file" ]; then
          umask 077
          ${pkgs.openssl}/bin/openssl rand -hex 32 > "$password_file"
        fi

        password=$(<"$password_file")
        umask 077
        ${pkgs.coreutils}/bin/install -m 0600 /dev/null ${databaseEnv}.new
        printf 'POSTGRES_PASSWORD=%s\n' "$password" > ${databaseEnv}.new
        ${pkgs.coreutils}/bin/mv ${databaseEnv}.new ${databaseEnv}

        ${pkgs.coreutils}/bin/install -m 0600 /dev/null ${apiEnv}.new
        printf 'UDASH_DB_URI=postgres://udash:%s@updates-dashboard-postgres:5432/udash?sslmode=disable\n' \
          "$password" > ${apiEnv}.new
        ${pkgs.coreutils}/bin/mv ${apiEnv}.new ${apiEnv}
      '';
    };

    updates-dashboard-database-ready = {
      description = "Wait for the Udash database";
      after = [ "docker-updates-dashboard-postgres.service" ];
      requires = [ "docker-updates-dashboard-postgres.service" ];
      serviceConfig.Type = "oneshot";
      script = ''
        attempt=0
        until [ "$(${docker} inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{end}}' updates-dashboard-postgres 2>/dev/null)" = healthy ]; do
          attempt=$((attempt + 1))
          if [ "$attempt" -ge 120 ]; then
            echo "Timed out waiting for the Udash database" >&2
            exit 1
          fi
          ${pkgs.coreutils}/bin/sleep 1
        done
      '';
    };

    updates-dashboard-api-ready = {
      description = "Wait for the Udash API";
      after = [ "docker-updates-dashboard-api.service" ];
      requires = [ "docker-updates-dashboard-api.service" ];
      serviceConfig.Type = "oneshot";
      script = ''
        attempt=0
        until [ "$(${docker} inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{end}}' updates-dashboard-api 2>/dev/null)" = healthy ]; do
          attempt=$((attempt + 1))
          if [ "$attempt" -ge 120 ]; then
            echo "Timed out waiting for the Udash API" >&2
            exit 1
          fi
          ${pkgs.coreutils}/bin/sleep 1
        done
      '';
    };

    updates-dashboard-oci-releases-report = reportService releaseInventory;
    updates-dashboard-oci-digests-report = reportService digestInventory;
    updates-dashboard-nix-report = (reportService nixInventory) // {
      serviceConfig = (reportService nixInventory).serviceConfig // {
        TimeoutStartSec = "6h";
      };
    };
  };

  systemd.timers = {
    updates-dashboard-oci-releases-report = {
      description = "Refresh the OCI release forecast in Udash";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnBootSec = "20min";
        OnCalendar = "daily";
        RandomizedDelaySec = "30min";
        Persistent = true;
      };
    };
    updates-dashboard-oci-digests-report = {
      description = "Refresh OCI digest drift in Udash";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnBootSec = "25min";
        OnCalendar = "daily";
        RandomizedDelaySec = "30min";
        Persistent = true;
      };
    };
    updates-dashboard-nix-report = {
      description = "Refresh the Nix closure forecast in Udash";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnBootSec = "30min";
        OnCalendar = "Sun *-*-* 05:00:00";
        RandomizedDelaySec = "1h";
        Persistent = true;
      };
    };
  };
}
