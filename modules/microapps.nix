{ config, lib, ... }:
let
  cfg = config.services.microapps;
  enabled = lib.filterAttrs (_: app: app.enable) cfg.apps;
  mkService = name: app: {
    description = "Internal micro app: ${name}";
    wantedBy = [ "multi-user.target" ];
    after = [ "network.target" ];
    environment = app.environment // {
      PORT = toString app.port;
    };
    serviceConfig = {
      ExecStart = lib.getExe app.package;
      DynamicUser = true;
      User = "microapp-${name}";
      StateDirectory = "microapp-${name}";
      StateDirectoryMode = "0700";
      LoadCredential = lib.mapAttrsToList (key: path: "${key}:${path}") app.credentials;
      Restart = "on-failure";
      UMask = "0077";
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
    };
  };
in
{
  options.services.microapps.apps = lib.mkOption {
    default = { };
    type = lib.types.attrsOf (
      lib.types.submodule {
        options = {
          enable = lib.mkEnableOption "this independent micro app";
          package = lib.mkOption { type = lib.types.package; };
          port = lib.mkOption { type = lib.types.port; };
          environment = lib.mkOption {
            type = lib.types.attrsOf lib.types.str;
            default = { };
          };
          credentials = lib.mkOption {
            type = lib.types.attrsOf lib.types.str;
            default = { };
          };
        };
      }
    );
    description = "Independent micro app services. Host nginx owns TLS and routing.";
  };
  config = {
    assertions = [
      {
        assertion =
          let
            ports = map (app: app.port) (builtins.attrValues enabled);
          in
          builtins.length ports == builtins.length (lib.unique ports);
        message = "Micro app ports must be unique";
      }
    ];
    systemd.services = lib.mapAttrs' (
      name: app: lib.nameValuePair "microapp-${name}" (mkService name app)
    ) enabled;
  };
}
