{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.services.notificationBridge;
  platform = import ../apps/notifications { inherit pkgs; };
  state = "/var/lib/microapp-notifications/state.sqlite";
in
{
  imports = [ ./microapps.nix ];
  options.services.notificationBridge = {
    enable = lib.mkEnableOption "the generic native notification bridge";
    origin = lib.mkOption { type = lib.types.str; };
    port = lib.mkOption {
      type = lib.types.port;
      default = 8094;
    };
    servicesFile = lib.mkOption {
      type = lib.types.str;
      description = "Root-only JSON service credentials and allowed origins/recipients; outside the Nix store.";
    };
    apnsKeyFile = lib.mkOption {
      type = lib.types.str;
      description = "Root-only APNs .p8 signing key; outside the Nix store.";
    };
    apnsKeyId = lib.mkOption { type = lib.types.str; };
    appleTeamId = lib.mkOption { type = lib.types.str; };
    bundleId = lib.mkOption {
      type = lib.types.str;
      default = "com.jmalexan.NotificationBridge";
    };
  };
  config = lib.mkIf cfg.enable {
    environment.systemPackages = [ platform.admin ];
    services.microapps.apps.notifications = {
      enable = true;
      package = platform.server;
      port = cfg.port;
      credentials.services = cfg.servicesFile;
      environment = {
        NOTIFICATIONS_ORIGIN = cfg.origin;
        NOTIFICATIONS_DATABASE = state;
        NOTIFICATIONS_SERVICES_FILE = "%d/services";
      };
    };
    systemd.services.microapp-notifications-delivery = {
      description = "Deliver generic native notifications through APNs";
      wantedBy = [ "multi-user.target" ];
      after = [ "microapp-notifications.service" ];
      requires = [ "microapp-notifications.service" ];
      environment = {
        NOTIFICATIONS_DATABASE = state;
        NOTIFICATIONS_APNS_KEY_FILE = "%d/apns";
        NOTIFICATIONS_APNS_KEY_ID = cfg.apnsKeyId;
        NOTIFICATIONS_APNS_TEAM_ID = cfg.appleTeamId;
        NOTIFICATIONS_APNS_TOPIC = cfg.bundleId;
      };
      serviceConfig = {
        Type = "simple";
        Restart = "on-failure";
        RestartSec = "10s";
        ExecStart = lib.getExe platform.worker;
        DynamicUser = true;
        User = "microapp-notifications";
        StateDirectory = "microapp-notifications";
        StateDirectoryMode = "0700";
        LoadCredential = [ "apns:${cfg.apnsKeyFile}" ];
        NoNewPrivileges = true;
        PrivateTmp = true;
        ProtectSystem = "strict";
        ProtectHome = true;
        ProtectKernelTunables = true;
        ProtectControlGroups = true;
        RestrictSUIDSGID = true;
        CapabilityBoundingSet = "";
        UMask = "0077";
      };
    };
  };
}
