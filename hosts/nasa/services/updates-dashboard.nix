{
  config,
  lib,
  pkgs,
  pkgs-unstable,
  vars,
  ...
}:
let
  reportState = "/var/lib/updates-dashboard-reporter";
  triggerState = "${reportState}/triggers";
  prQueue = "${reportState}/pr-queue";
  prResults = "${reportState}/pr-results";
  githubToken = config.age.secrets.updates-dashboard-github-token.path;
  repositoryName = lib.removePrefix "github:" vars.repository;
  repositoryUrl = "https://github.com/${repositoryName}.git";

  containerMetadata = {
    bookorbit.releaseNotes = {
      repository = "bookorbit/bookorbit";
      tagPrefix = "v";
    };
    "eufy-security-ws".releaseNotes.repository = "bropat/eufy-security-ws";
    flaresolverr.releaseNotes = {
      repository = "FlareSolverr/FlareSolverr";
      tagPrefix = "v";
    };
    frigate.releaseNotes = {
      repository = "blakeblackshear/frigate";
      tagPrefix = "v";
      stripSuffix = "-tensorrt";
    };
    go2rtc.releaseNotes = {
      repository = "AlexxIT/go2rtc";
      tagPrefix = "v";
    };
    "home-assistant".releaseNotes.repository = "home-assistant/core";
    "immich-machine-learning" = {
      updateGroup = "Immich application images";
      releaseNotes = {
        repository = "immich-app/immich";
        tagPrefix = "v";
      };
    };
    "immich-server" = {
      updateGroup = "Immich application images";
      releaseNotes = {
        repository = "immich-app/immich";
        tagPrefix = "v";
      };
    };
    "immich-public-proxy".releaseNotes = {
      repository = "alangrainger/immich-public-proxy";
      tagPrefix = "v";
    };
    "music-assistant".releaseNotes.repository = "music-assistant/server";
    "ring-mqtt".releaseNotes = {
      repository = "tsightler/ring-mqtt";
      tagPrefix = "v";
    };
    romm.releaseNotes.repository = "rommapp/romm";
    "romm-db".releaseNotes = {
      repository = "MariaDB/server";
      tagPrefix = "mariadb-";
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
    }
    .${name} or {
      kind = "semver";
    };

  containerImages = lib.mapAttrs (
    _: container: parseImage container.image
  ) config.virtualisation.oci-containers.containers;

  inventory = pkgs.writeText "updates-dashboard-inventory.json" (
    builtins.toJSON {
      services = lib.mapAttrsToList (
        name: image:
        {
          inherit name;
          inherit (image) repository;
          currentTag = image.tag;
          currentDigest = image.digest;
        }
        // (containerMetadata.${name} or { })
      ) containerImages;
    }
  );

  dashboardReporter = pkgs.writeTextFile {
    name = "update-dashboard-reporter";
    destination = "/bin/update-dashboard-reporter";
    executable = true;
    text = ''
      #!${pkgs.python3}/bin/python3
      ${builtins.readFile ./updates-dashboard/reporter.py}
    '';
  };

  dashboardServer = pkgs.writeTextFile {
    name = "update-dashboard-server";
    destination = "/bin/update-dashboard-server";
    executable = true;
    text = ''
      #!${pkgs.python3}/bin/python3
      ${builtins.readFile ./updates-dashboard/server.py}
    '';
  };

  dashboardStatic = pkgs.runCommand "update-dashboard-static" { } ''
    mkdir -p "$out"
    cp ${./updates-dashboard/index.html} "$out/index.html"
    cp ${./updates-dashboard/app.js} "$out/app.js"
    cp ${./updates-dashboard/styles.css} "$out/styles.css"
  '';

  recordCommand =
    kind: name: image:
    lib.escapeShellArgs [
      "${dashboardReporter}/bin/update-dashboard-reporter"
      "record"
      kind
      "${reportState}/${kind}.items.jsonl"
      name
      image.repository
      image.tag
      image.digest
    ];

  # Updatecli remains useful as a registry/version-policy engine. Its shell
  # targets now write a normalized row for our UI instead of publishing Udash's
  # source/target/action representation.
  releaseSources = lib.mapAttrs (name: image: {
    name = "${name} (installed: ${image.tag})";
    kind = "dockerimage";
    spec = {
      image = image.repository;
      versionfilter = versionFilter name;
    };
  }) containerImages;

  releaseTargets = lib.mapAttrs (name: image: {
    name = "${name}: record newest compatible tag";
    kind = "shell";
    sourceid = name;
    spec.command = recordCommand "releases" name image;
  }) containerImages;

  # Skopeo reports the image-index digest consistently. Updatecli's native
  # dockerdigest source can resolve multi-platform tags to an amd64 child and
  # create a permanent false alert against Renovate's index digest.
  registryDigest = pkgs.writeShellApplication {
    name = "registry-index-digest";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.skopeo
    ];
    text = ''
      repository="''${1:?image repository is required}"
      tag="''${2:?image tag is required}"

      for attempt in 1 2 3 4; do
        if digest=$(skopeo inspect --no-tags --format "{{.Digest}}" "docker://$repository:$tag"); then
          printf '%s@%s\n' "$tag" "$digest"
          exit 0
        fi

        if [ "$attempt" -eq 4 ]; then
          printf 'Digest lookup failed after %s attempts: %s:%s\n' \
            "$attempt" "$repository" "$tag" >&2
          exit 1
        fi

        delay=$((1 << attempt))
        printf 'Digest lookup attempt %s failed; retrying in %ss: %s:%s\n' \
          "$attempt" "$delay" "$repository" "$tag" >&2
        sleep "$delay"
      done
    '';
  };

  digestSources = lib.mapAttrs (_name: image: {
    name = "Registry digest for ${image.repository}:${image.tag}";
    kind = "shell";
    spec.command = "${registryDigest}/bin/registry-index-digest ${lib.escapeShellArg image.repository} ${lib.escapeShellArg image.tag}";
  }) containerImages;

  digestTargets = lib.mapAttrs (name: image: {
    name = "${name}: record current registry digest";
    kind = "shell";
    sourceid = name;
    spec.command = recordCommand "digests" name image;
  }) containerImages;

  releaseInventory = pkgs.writeText "updatecli-oci-releases.json" (
    builtins.toJSON {
      name = "Container release scan";
      sources = releaseSources;
      targets = releaseTargets;
    }
  );

  digestInventory = pkgs.writeText "updatecli-oci-digests.json" (
    builtins.toJSON {
      name = "Container digest scan";
      sources = digestSources;
      targets = digestTargets;
    }
  );

  reportService = kind: configFile: {
    description = "Refresh the ${kind} data in Update Watch";
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];
    wantedBy = [ "multi-user.target" ];
    environment.HOME = reportState;
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
      ${pkgs.coreutils}/bin/rm -f ${triggerState}/${kind}
      items=${reportState}/${kind}.items.jsonl
      : > "$items"

      set +e
      ${pkgs-unstable.updatecli}/bin/updatecli pipeline diff --config ${configFile}
      scanner_status=$?
      set -e

      ${dashboardReporter}/bin/update-dashboard-reporter finalize \
        ${kind} ${inventory} "$items" ${reportState}/${kind}.json "$scanner_status"
      exit "$scanner_status"
    '';
  };

  triggerPathUnit = target: unit: {
    description = "Watch for an on-demand ${target} update scan";
    wantedBy = [ "paths.target" ];
    pathConfig = {
      PathExists = "${triggerState}/${target}";
      Unit = unit;
    };
  };
in
{
  age.secrets.updates-dashboard-github-token = {
    file = ../../../secrets/updates-dashboard-github-token.age;
    owner = "updates-dashboard-reporter";
    group = "updates-dashboard-reporter";
    mode = "0400";
  };

  users.users.updates-dashboard-reporter = {
    isSystemUser = true;
    group = "updates-dashboard-reporter";
    home = reportState;
  };
  users.groups.updates-dashboard-reporter = { };
  users.users.updates-dashboard-server = {
    isSystemUser = true;
    group = "updates-dashboard-reporter";
  };

  systemd.tmpfiles.rules = [
    "d ${reportState} 0750 updates-dashboard-reporter updates-dashboard-reporter -"
    "d ${triggerState} 0770 updates-dashboard-reporter updates-dashboard-reporter -"
    "d ${prQueue} 0770 updates-dashboard-reporter updates-dashboard-reporter -"
    "d ${prResults} 0770 updates-dashboard-reporter updates-dashboard-reporter -"
  ];

  systemd.services = {
    updates-dashboard = {
      description = "System updates dashboard";
      wantedBy = [ "multi-user.target" ];
      after = [ "network.target" ];
      serviceConfig = {
        Type = "simple";
        User = "updates-dashboard-server";
        Group = "updates-dashboard-reporter";
        ExecStart = lib.escapeShellArgs [
          "${dashboardServer}/bin/update-dashboard-server"
          "--listen"
          "127.0.0.1"
          "--port"
          "8091"
          "--static"
          dashboardStatic
          "--data"
          reportState
          "--inventory"
          inventory
          "--systemctl"
          "${pkgs.systemd}/bin/systemctl"
          "--token"
          githubToken
        ];
        Restart = "on-failure";
        RestartSec = 2;
        NoNewPrivileges = true;
        PrivateTmp = true;
        ProtectSystem = "strict";
        ProtectHome = true;
        ReadWritePaths = [
          triggerState
          prQueue
          prResults
        ];
        RestrictAddressFamilies = [
          "AF_UNIX"
          "AF_INET"
          "AF_INET6"
        ];
      };
    };

    updates-dashboard-oci-releases-report = reportService "releases" releaseInventory;
    updates-dashboard-oci-digests-report = (reportService "digests" digestInventory) // {
      # Both lightweight reports start after boot/deployment. Let the release
      # inventory finish first so they do not burst the resolver together.
      after = [
        "network-online.target"
        "updates-dashboard-oci-releases-report.service"
      ];
    };
    updates-dashboard-actions-report = {
      description = "Refresh GitHub Action versions in the system updates dashboard";
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];
      wantedBy = [ "multi-user.target" ];
      environment.HOME = reportState;
      serviceConfig = {
        Type = "oneshot";
        User = "updates-dashboard-reporter";
        Group = "updates-dashboard-reporter";
        StateDirectory = "updates-dashboard-reporter";
        CacheDirectory = "updates-dashboard-reporter";
        PrivateTmp = true;
        NoNewPrivileges = true;
        Nice = 10;
      };
      script = ''
        ${pkgs.coreutils}/bin/rm -f ${triggerState}/actions
        ${dashboardReporter}/bin/update-dashboard-reporter actions-scan \
          ${reportState}/actions.json \
          ${lib.escapeShellArg repositoryUrl} \
          ${pkgs.git}/bin/git
      '';
    };
    updates-dashboard-nix-report = {
      description = "Refresh the Nix closure forecast in Update Watch";
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];
      environment.HOME = reportState;
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
        TimeoutStartSec = "6h";
      };
      script = ''
        ${pkgs.coreutils}/bin/rm -f ${triggerState}/nix
        ${dashboardReporter}/bin/update-dashboard-reporter nix-scan \
          ${reportState}/nix.json \
          ${lib.escapeShellArg repositoryUrl} \
          ${pkgs.git}/bin/git \
          ${pkgs.nix}/bin/nix \
          --max-jobs 1 \
          --cores 8
      '';
    };
    updates-dashboard-pr = {
      description = "Create dependency pull requests requested by the system updates dashboard";
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];
      environment.HOME = reportState;
      serviceConfig = {
        Type = "oneshot";
        User = "updates-dashboard-reporter";
        Group = "updates-dashboard-reporter";
        StateDirectory = "updates-dashboard-reporter";
        CacheDirectory = "updates-dashboard-reporter";
        PrivateTmp = true;
        NoNewPrivileges = true;
        Nice = 10;
        TimeoutStartSec = "1h";
      };
      script = ''
        ${dashboardReporter}/bin/update-dashboard-reporter pr-queue \
          ${prQueue} \
          ${prResults} \
          ${reportState} \
          ${inventory} \
          ${lib.escapeShellArg repositoryUrl} \
          ${lib.escapeShellArg repositoryName} \
          ${githubToken} \
          ${pkgs.git}/bin/git \
          ${pkgs.nix}/bin/nix \
          ${pkgs.skopeo}/bin/skopeo
      '';
    };
  };

  systemd.paths = {
    updates-dashboard-trigger-releases = triggerPathUnit "releases" "updates-dashboard-oci-releases-report.service";
    updates-dashboard-trigger-digests = triggerPathUnit "digests" "updates-dashboard-oci-digests-report.service";
    updates-dashboard-trigger-actions = triggerPathUnit "actions" "updates-dashboard-actions-report.service";
    updates-dashboard-trigger-nix = triggerPathUnit "nix" "updates-dashboard-nix-report.service";
    updates-dashboard-pr = {
      description = "Watch for dependency pull requests requested by the dashboard";
      wantedBy = [ "paths.target" ];
      pathConfig = {
        DirectoryNotEmpty = prQueue;
        Unit = "updates-dashboard-pr.service";
      };
    };
  };

  systemd.timers = {
    updates-dashboard-oci-releases-report = {
      description = "Refresh container releases in Update Watch";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnCalendar = "daily";
        RandomizedDelaySec = "30min";
        Persistent = true;
      };
    };
    updates-dashboard-oci-digests-report = {
      description = "Refresh container digests in Update Watch";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnCalendar = "daily";
        RandomizedDelaySec = "30min";
        Persistent = true;
      };
    };
    updates-dashboard-actions-report = {
      description = "Refresh GitHub Action versions in the system updates dashboard";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnCalendar = "daily";
        RandomizedDelaySec = "30min";
        Persistent = true;
      };
    };
    updates-dashboard-nix-report = {
      description = "Refresh the Nix closure forecast in Update Watch";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnCalendar = "*-*-* 05:00:00";
        RandomizedDelaySec = "1h";
        Persistent = true;
      };
    };
  };
}
