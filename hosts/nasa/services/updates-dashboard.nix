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
  repositoryUrl = "https://github.com/${lib.removePrefix "github:" vars.repository}.git";

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
      services = lib.mapAttrsToList (name: image: {
        inherit name;
        inherit (image) repository;
        currentTag = image.tag;
        currentDigest = image.digest;
      }) containerImages;
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
    runtimeInputs = [ pkgs.skopeo ];
    text = ''
      repository="''${1:?image repository is required}"
      tag="''${2:?image tag is required}"
      digest=$(skopeo inspect --format "{{.Digest}}" "docker://$repository:$tag")
      printf '%s@%s\n' "$tag" "$digest"
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
in
{
  users.users.updates-dashboard-reporter = {
    isSystemUser = true;
    group = "updates-dashboard-reporter";
    home = reportState;
  };
  users.groups.updates-dashboard-reporter = { };

  systemd.services = {
    updates-dashboard = {
      description = "Update Watch read-only dashboard";
      wantedBy = [ "multi-user.target" ];
      after = [ "network.target" ];
      serviceConfig = {
        Type = "simple";
        User = "updates-dashboard-reporter";
        Group = "updates-dashboard-reporter";
        StateDirectory = "updates-dashboard-reporter";
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
        ];
        Restart = "on-failure";
        RestartSec = 2;
        NoNewPrivileges = true;
        PrivateTmp = true;
        ProtectSystem = "strict";
        ProtectHome = true;
        RestrictAddressFamilies = [
          "AF_INET"
          "AF_INET6"
        ];
      };
    };

    updates-dashboard-oci-releases-report = reportService "releases" releaseInventory;
    updates-dashboard-oci-digests-report = reportService "digests" digestInventory;
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
        ${dashboardReporter}/bin/update-dashboard-reporter nix-scan \
          ${reportState}/nix.json \
          ${lib.escapeShellArg repositoryUrl} \
          ${pkgs.git}/bin/git \
          ${pkgs.nix}/bin/nix \
          --max-jobs 1 \
          --cores 8
      '';
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
    updates-dashboard-nix-report = {
      description = "Refresh the Nix closure forecast in Update Watch";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnCalendar = "Sun *-*-* 05:00:00";
        RandomizedDelaySec = "1h";
        Persistent = true;
      };
    };
  };
}
