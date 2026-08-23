{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.services.rommIgir;

  jobType = lib.types.submodule {
    options = {
      inputs = lib.mkOption {
        type = lib.types.nonEmptyListOf lib.types.str;
        description = "Absolute torrent paths or globs to pass as repeated Igir --input arguments.";
      };

      dats = lib.mkOption {
        type = lib.types.nonEmptyListOf lib.types.str;
        description = "Absolute DAT paths or globs to pass as repeated Igir --dat arguments.";
      };

      platformSlug = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        example = "gba";
        description = ''
          Explicit RomM platform slug for this job. When null, Igir's {romm}
          output token chooses a slug from each DAT.
        '';
      };

      outputConsoleTokens = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        example = "/Data/smb/Games/DATs/romm-console-tokens.json";
        description = "Absolute path to a custom Igir --output-console-tokens JSON file.";
      };

      extraArgs = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ ];
        example = [
          "--merge-roms"
          "split"
        ];
        description = ''
          Additional Igir options applied to both the ROM and BIOS passes.
          Commands and workflow-owned input, output, link, and BIOS options are rejected.
        '';
      };

      roms = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Run the non-BIOS pass for this job.";
      };

      bios = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Run the BIOS-only pass for this job.";
      };

      verify = lib.mkOption {
        type = lib.types.nullOr lib.types.bool;
        default = null;
        description = "Override services.rommIgir.verify for this job.";
      };
    };
  };

  forbiddenArgs = [
    "clean"
    "copy"
    "dir2dat"
    "extract"
    "fixdat"
    "link"
    "move"
    "playlist"
    "report"
    "test"
    "zip"
    "--dat"
    "-d"
    "--input"
    "-i"
    "--link-mode"
    "--no-bios"
    "--only-bios"
    "--output"
    "-o"
    "--output-console-tokens"
    "--overwrite"
    "-O"
    "--overwrite-invalid"
    "--symlink-relative"
  ];

  hasForbiddenArg =
    arg:
    builtins.elem arg forbiddenArgs
    || lib.any (prefix: lib.hasPrefix "${prefix}=" arg) (
      lib.filter (arg': lib.hasPrefix "--" arg') forbiddenArgs
    );

  outputToken = job: if job.platformSlug == null then "{romm}" else job.platformSlug;
  shouldVerify = job: if job.verify == null then cfg.verify else job.verify;

  commonArgs =
    job:
    [
      "--link-mode"
      "symlink"
      "--overwrite-invalid"
      "--cache-path"
      cfg.cachePath
    ]
    ++ lib.concatMap (dat: [
      "--dat"
      dat
    ]) job.dats
    ++ lib.concatMap (input: [
      "--input"
      input
    ]) job.inputs
    ++ lib.optionals (job.outputConsoleTokens != null) [
      "--output-console-tokens"
      job.outputConsoleTokens
    ]
    ++ job.extraArgs
    ++ lib.optional cfg.verbose "-v";

  invocation =
    job: kind:
    let
      commands = [ "link" ] ++ lib.optional (shouldVerify job) "test";
      modeArg = if kind == "roms" then "--no-bios" else "--only-bios";
      output = "${cfg.libraryPath}/${kind}/${outputToken job}";
      args = commonArgs job ++ [
        "--output"
        output
        modeArg
      ];
    in
    "${lib.getExe cfg.package} ${lib.escapeShellArgs commands} ${lib.escapeShellArgs args}";

  renderJob =
    name: job:
    lib.concatStringsSep "\n" (
      [ "echo ${lib.escapeShellArg "Running RomM Igir job: ${name}"}" ]
      ++ lib.optional job.roms (invocation job "roms")
      ++ lib.optional job.bios (invocation job "bios")
    );

  runner = pkgs.writeShellApplication {
    name = "romm-igir-link";
    runtimeInputs = [
      cfg.package
      pkgs.coreutils
      # Igir's update check invokes awk through /bin/sh. systemd gives this
      # runner an isolated PATH, so declare it instead of relying on the host.
      pkgs.gawk
    ];
    text = ''
      mkdir -p \
        ${lib.escapeShellArg "${cfg.libraryPath}/roms"} \
        ${lib.escapeShellArg "${cfg.libraryPath}/bios"}

      ${
        if cfg.jobs == { } then
          ''echo "No services.rommIgir.jobs are configured; nothing to do."''
        else
          lib.concatStringsSep "\n" (lib.mapAttrsToList renderJob cfg.jobs)
      }
    '';
  };

  jobAssertions = lib.concatLists (
    lib.mapAttrsToList (name: job: [
      {
        assertion = builtins.match "^[A-Za-z0-9_-]+$" name != null;
        message = "services.rommIgir.jobs names may contain only letters, digits, underscores, and hyphens";
      }
      {
        assertion = lib.all (lib.hasPrefix "/") (job.inputs ++ job.dats);
        message = "services.rommIgir.jobs.${name} input and DAT paths/globs must be absolute";
      }
      {
        assertion = lib.all (
          input:
          lib.any (
            root: input == root || lib.hasPrefix "${lib.removeSuffix "/" root}/" input
          ) cfg.torrentRoots
        ) job.inputs;
        message = "services.rommIgir.jobs.${name} inputs must be beneath a mounted services.rommIgir.torrentRoots path";
      }
      {
        assertion = job.roms || job.bios;
        message = "services.rommIgir.jobs.${name} must enable at least one of roms or bios";
      }
      {
        assertion =
          job.platformSlug == null || builtins.match "^[a-z0-9][a-z0-9_-]*$" job.platformSlug != null;
        message = "services.rommIgir.jobs.${name}.platformSlug must be a RomM-style lowercase slug";
      }
      {
        assertion = job.outputConsoleTokens == null || lib.hasPrefix "/" job.outputConsoleTokens;
        message = "services.rommIgir.jobs.${name}.outputConsoleTokens must be an absolute path";
      }
      {
        assertion = !lib.any hasForbiddenArg job.extraArgs;
        message = "services.rommIgir.jobs.${name}.extraArgs attempts to override a protected workflow command or option";
      }
    ]) cfg.jobs
  );
in
{
  options.services.rommIgir = {
    enable = lib.mkEnableOption "Igir symlink generation for RomM";

    package = lib.mkPackageOption pkgs "igir" { };

    libraryPath = lib.mkOption {
      type = lib.types.str;
      default = "/Data/smb/Games/Library";
      description = "Host path to the RomM Structure A library.";
    };

    torrentRoots = lib.mkOption {
      type = lib.types.nonEmptyListOf lib.types.str;
      default = [ "/Data/smb/Torrents" ];
      description = ''
        Absolute torrent roots to mount read-only into the RomM container at
        identical paths, so absolute symlink targets remain resolvable.
      '';
    };

    user = lib.mkOption {
      type = lib.types.str;
      default = "jmalexan";
      description = "Account that runs Igir and owns newly-created links.";
    };

    group = lib.mkOption {
      type = lib.types.str;
      default = "media";
      description = "Primary group for the Igir service.";
    };

    verify = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Add Igir's test command to routine ROM and BIOS passes.";
    };

    cachePath = lib.mkOption {
      type = lib.types.str;
      # Reuse the cache populated by the original console-1g1r job. Both
      # current jobs scan identical inputs and DATs, and run serially.
      default = "/var/cache/romm-igir/console-1g1r.cache";
      description = "Shared Igir file cache used by every configured job.";
    };

    verbose = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Enable Igir's per-file informational logging.";
    };

    jobs = lib.mkOption {
      type = lib.types.attrsOf jobType;
      default = { };
      description = "Named groups of torrent inputs and matching DAT sets.";
    };

    timer = {
      enable = lib.mkEnableOption "scheduled RomM Igir reruns";

      onCalendar = lib.mkOption {
        type = lib.types.str;
        default = "daily";
        description = "systemd OnCalendar expression for Igir reruns.";
      };

      randomizedDelaySec = lib.mkOption {
        type = lib.types.str;
        default = "1h";
        description = "Maximum randomized delay applied to scheduled runs.";
      };
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = lib.hasPrefix "/" cfg.libraryPath;
        message = "services.rommIgir.libraryPath must be absolute";
      }
      {
        assertion = lib.hasPrefix "/var/cache/romm-igir/" cfg.cachePath;
        message = "services.rommIgir.cachePath must be inside the service CacheDirectory";
      }
      {
        assertion = lib.all (root: lib.hasPrefix "/" root && !lib.hasInfix ":" root) cfg.torrentRoots;
        message = "services.rommIgir.torrentRoots must contain absolute paths without colons";
      }
      {
        assertion = !cfg.timer.enable || cfg.jobs != { };
        message = "services.rommIgir.timer cannot be enabled without at least one job";
      }
    ]
    ++ jobAssertions;

    environment.systemPackages = [
      cfg.package
      runner
    ];

    # Igir writes absolute links. Give the container the same source paths so
    # those links resolve after the library is bind-mounted at /romm/library.
    virtualisation.oci-containers.containers.romm.volumes = lib.mkAfter (
      map (root: "${root}:${root}:ro") cfg.torrentRoots
    );

    systemd.services.romm-igir-link = {
      description = "Link torrent ROMs and BIOS files into the RomM library with Igir";
      after = [ "zfs-mount.service" ];
      requires = [ "zfs-mount.service" ];
      unitConfig.AssertPathIsMountPoint = "/Data/smb";
      serviceConfig = {
        Type = "oneshot";
        User = cfg.user;
        Group = cfg.group;
        UMask = "0022";
        CacheDirectory = "romm-igir";
        CacheDirectoryMode = "0750";
        ExecStart = lib.getExe runner;
        WorkingDirectory = cfg.libraryPath;
        Nice = 10;
        IOSchedulingClass = "idle";
        TimeoutStartSec = "infinity";
        NoNewPrivileges = true;
        PrivateTmp = true;
        ProtectHome = true;
        ProtectSystem = "strict";
        ReadWritePaths = [ cfg.libraryPath ];
      };
    };

    systemd.timers.romm-igir-link = lib.mkIf cfg.timer.enable {
      description = "Periodically refresh Igir links for RomM";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnCalendar = cfg.timer.onCalendar;
        RandomizedDelaySec = cfg.timer.randomizedDelaySec;
        Persistent = true;
        Unit = "romm-igir-link.service";
      };
    };
  };
}
