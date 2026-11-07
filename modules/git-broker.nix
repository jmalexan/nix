{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.services.gitBroker;
  platform = import ../apps/git-broker { inherit pkgs; };
  repositories = pkgs.writeText "git-broker-repositories.json" (builtins.toJSON cfg.repositories);
in
{
  options.services.gitBroker = {
    enable = lib.mkEnableOption "the credential-isolating Git broker";
    port = lib.mkOption {
      type = lib.types.port;
      default = 8097;
    };
    repositories = lib.mkOption {
      default = { };
      type = lib.types.attrsOf (
        lib.types.submodule {
          options = {
            github = lib.mkOption {
              type = lib.types.str;
              description = "Exact owner/repository on github.com";
            };
            write_prefixes = lib.mkOption {
              type = lib.types.listOf lib.types.str;
              default = [ ];
              description = "Allowed top-level branch namespaces, e.g. robot/. Empty means read-only.";
            };
          };
        }
      );
    };
    repositoriesFile = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "Root-only JSON allowlist, for private repository names kept out of public Nix configuration.";
    };
    clientTokenFile = lib.mkOption {
      type = lib.types.str;
      description = "Root-only broker client token; no upstream authority.";
    };
    upstreamTokenFile = lib.mkOption {
      type = lib.types.str;
      description = "Root-only GitHub token, retained on the trusted host.";
    };
    approvalOrigin = lib.mkOption {
      type = lib.types.str;
      default = "https://approve.nasa.jmalexan.com";
    };
    approvalTokenFile = lib.mkOption {
      type = lib.types.str;
      description = "Host-only credential for claiming exact push approvals; never sent to the VM.";
    };
    maxBundleBytes = lib.mkOption {
      type = lib.types.ints.positive;
      default = 134217728;
    };
  };
  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = (cfg.repositories != { }) != (cfg.repositoriesFile != null);
        message = "Git broker requires exactly one explicit repository allowlist source";
      }
    ];
    systemd.services.git-broker = {
      description = "Allowlisted Git broker";
      wantedBy = [ "multi-user.target" ];
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];
      environment = {
        PORT = toString cfg.port;
        GIT_BROKER_STATE = "/var/lib/git-broker";
        GIT_BROKER_REPOSITORIES =
          if cfg.repositoriesFile == null then "${repositories}" else "%d/repositories";
        GIT_BROKER_CLIENT_TOKEN = "%d/client";
        GIT_BROKER_UPSTREAM_TOKEN = "%d/upstream";
        GIT_BROKER_APPROVAL_ORIGIN = cfg.approvalOrigin;
        GIT_BROKER_APPROVAL_TOKEN = "%d/approval";
        GIT_BROKER_MAX_BYTES = toString cfg.maxBundleBytes;
      };
      serviceConfig = {
        ExecStart = lib.getExe platform.server;
        DynamicUser = true;
        StateDirectory = "git-broker";
        StateDirectoryMode = "0700";
        UMask = "0077";
        LoadCredential = [
          "client:${cfg.clientTokenFile}"
          "upstream:${cfg.upstreamTokenFile}"
          "approval:${cfg.approvalTokenFile}"
        ]
        ++ lib.optional (cfg.repositoriesFile != null) "repositories:${cfg.repositoriesFile}";
        Restart = "on-failure";
        RestartSec = "5s";
        NoNewPrivileges = true;
        PrivateTmp = true;
        ProtectSystem = "strict";
        ProtectHome = true;
        ProtectKernelTunables = true;
        ProtectControlGroups = true;
        RestrictSUIDSGID = true;
        CapabilityBoundingSet = "";
        RestrictAddressFamilies = [
          "AF_UNIX"
          "AF_INET"
          "AF_INET6"
        ];
        MemoryMax = "1G";
        TasksMax = 64;
        LimitFSIZE = "1G";
      };
    };
  };
}
