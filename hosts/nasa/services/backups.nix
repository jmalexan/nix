{
  config,
  lib,
  pkgs,
  vars,
  ...
}:
let
  app = import ../../../apps/backups { inherit pkgs; };
  notifications = import ../../../apps/notifications { inherit pkgs; };
  origin = "https://backups.${vars.nasa.domain}";
  port = 8101;
  reportRoot = "/var/lib/backups-collector";
  authRoot = "/var/lib/backups-auth";
  publisher = "/var/lib/microapp-secrets/backups/publisher";
  backup = config.services.restic.backups.backblaze;
  inventory = pkgs.writeText "backup-monitor-inventory.json" (
    builtins.toJSON {
      hostname = config.networking.hostName;
      inherit (backup) repository paths;
      exclusions = map (lib.removePrefix "--exclude=") (
        builtins.filter (lib.hasPrefix "--exclude=") backup.extraBackupArgs
      );
      retention = backup.pruneOpts;
    }
  );
  pythonPath = "${../../../apps/backups}:${../../../apps/microapps/backend}";
  record = phase: ''
    if ! PYTHONPATH=${pythonPath} ${app.python}/bin/python ${../../../apps/backups/collector.py} --root ${reportRoot} --record ${phase}; then
      echo "Backup monitoring event could not be recorded" >&2
    fi
  '';
  hardened = {
    NoNewPrivileges = true;
    PrivateTmp = true;
    ProtectSystem = "strict";
    ProtectHome = true;
    ProtectKernelTunables = true;
    ProtectControlGroups = true;
    RestrictSUIDSGID = true;
    UMask = "0027";
  };
in
{
  assertions = [
    {
      assertion =
        !(builtins.elem port (
          [
            8091
            8095
            8096
          ]
          ++ lib.optional config.services.open-webui.enable config.services.open-webui.port
          ++ lib.optional config.services.notificationBridge.enable config.services.notificationBridge.port
          ++ lib.optional config.services.gitBroker.enable config.services.gitBroker.port
          ++ map (app: app.port) (
            builtins.attrValues (lib.filterAttrs (_: app: app.enable) config.services.microapps.apps)
          )
        ));
      message = "Backups must use a different port from other NASA app listeners";
    }
  ];
  users.groups.backups-report = { };
  users.users.backups-web = {
    isSystemUser = true;
    group = "backups-report";
  };
  users.users.backups-notify = {
    isSystemUser = true;
    group = "backups-report";
  };
  systemd.tmpfiles.rules = [ "d ${reportRoot} 0750 root backups-report -" ];
  services.restic.backups.backblaze.paths = [ publisher ];
  # Record the whole backup/prune result, including partial backups (exit 3).
  # These probes neither alter Restic arguments nor suppress its failures.
  systemd.services.restic-backups-backblaze = {
    preStart = lib.mkBefore (record "start");
    postStop = lib.mkBefore (record "finish");
  };
  systemd.services.backups-publisher-credentials = {
    description = "Provision Backups notification credentials";
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      UMask = "0077";
    };
    environment.PYTHONPATH = "${../../../apps/microapps/backend}:${../../../apps/notifications/backend}";
    script = ''
      ${notifications.python}/bin/python -m notifications.bootstrap \
        --registry ${lib.escapeShellArg config.services.notificationBridge.servicesFile} \
        --publisher ${publisher} --service backups --origin ${lib.escapeShellArg origin} --additional-origin https://backups
    '';
  };
  services.microappAccounts.clients = [ "backups-web" ];
  systemd.services.backups-web = {
    stopIfChanged = false;
    description = "ZFS and offsite backup dashboard";
    wantedBy = [ "multi-user.target" ];
    requires = [ "backups-publisher-credentials.service" ];
    after = [
      "network.target"
      "backups-publisher-credentials.service"
    ];
    environment = {
      PORT = toString port;
      BACKUPS_ORIGIN = origin;
      BACKUPS_DATABASE = "${authRoot}/state.sqlite";
      BACKUPS_ALIASES = "https://backups";
      BACKUPS_REPORT = "${reportRoot}/report.json";
      BACKUPS_STATIC = "${app.static}";
    };
    serviceConfig = hardened // {
      User = "backups-web";
      Group = "backups-report";
      ExecStart = lib.getExe app.server;
      StateDirectory = "backups-auth";
      StateDirectoryMode = "0700";
      Restart = "on-failure";
      CapabilityBoundingSet = "";
      RestrictAddressFamilies = [
        "AF_UNIX"
        "AF_INET"
        "AF_INET6"
      ];
    };
  };
  systemd.services.backups-collector = {
    description = "Read ZFS and offsite backup status";
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];
    path = [
      pkgs.zfs
      pkgs.restic
      pkgs.systemd
    ];
    environment = {
      PYTHONPATH = pythonPath;
      RESTIC_REPOSITORY = backup.repository;
      RESTIC_PASSWORD_FILE = "%d/password";
      RESTIC_CACHE_DIR = "/var/cache/backups-collector";
    };
    serviceConfig = hardened // {
      Type = "oneshot";
      User = "root";
      Group = "backups-report";
      StateDirectory = "backups-collector";
      StateDirectoryMode = "0750";
      CacheDirectory = "backups-collector";
      EnvironmentFile = backup.environmentFile;
      LoadCredential = [ "password:${backup.passwordFile}" ];
      TimeoutStartSec = "5min";
      # ZFS status requires device access. The web and notifier have none.
      ExecStart = "${app.python}/bin/python ${../../../apps/backups/collector.py} --root ${reportRoot} --config ${inventory}";
    };
  };
  systemd.services.backups-notify = {
    description = "Notify about failed or overdue storage protection";
    requires = [ "backups-publisher-credentials.service" ];
    after = [
      "backups-publisher-credentials.service"
      "microapp-notifications.service"
      "nginx.service"
      "backups-collector.service"
    ];
    environment = {
      PYTHONPATH = pythonPath;
      BACKUPS_REPORT = "${reportRoot}/report.json";
      BACKUPS_NOTIFY_STATE = "/var/lib/backups-notify/state.json";
      BACKUPS_ORIGIN = "https://backups";
      NOTIFICATIONS_ORIGIN = config.services.notificationBridge.origin;
      NOTIFICATIONS_TOKEN_FILE = "%d/publisher";
    };
    serviceConfig = hardened // {
      Type = "oneshot";
      User = "backups-notify";
      Group = "backups-report";
      StateDirectory = "backups-notify";
      StateDirectoryMode = "0700";
      LoadCredential = [ "publisher:${publisher}" ];
      CapabilityBoundingSet = "";
      TimeoutStartSec = "1min";
      ExecStart = "${app.python}/bin/python ${../../../apps/backups/notify.py}";
    };
  };
  systemd.services.microapp-notifications = {
    requires = [ "backups-publisher-credentials.service" ];
    after = [ "backups-publisher-credentials.service" ];
  };
  systemd.timers.backups-collector = {
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnBootSec = "30s";
      OnUnitActiveSec = "15min";
    };
  };
  systemd.timers.backups-notify = {
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnBootSec = "6min";
      OnUnitActiveSec = "5min";
    };
  };
  systemd.services.backups-auth-backup = {
    description = "Consistent Backups authentication database backup";
    requires = [ "backups-web.service" ];
    after = [ "backups-web.service" ];
    unitConfig.AssertPathIsMountPoint = "/Data/smb";
    serviceConfig.Type = "oneshot";
    script = ''
      install -d -m 0700 /Data/smb/Internal/Backups/microapps
      ${app.python}/bin/python - <<'PY'
      import os, sqlite3, tempfile
      from pathlib import Path
      destination = Path('/Data/smb/Internal/Backups/microapps/backups-auth.sqlite')
      fd, temporary = tempfile.mkstemp(dir=destination.parent, prefix='.backups-auth-')
      os.close(fd)
      try:
          with sqlite3.connect('file:${authRoot}/state.sqlite?mode=ro', uri=True) as source:
              with sqlite3.connect(temporary) as target:
                  source.backup(target)
          os.replace(temporary, destination)
      finally:
          Path(temporary).unlink(missing_ok=True)
      PY
    '';
  };
  systemd.services.database-backup = {
    requires = [ "backups-auth-backup.service" ];
    after = [ "backups-auth-backup.service" ];
  };
  services.nginx.virtualHosts."backups.${vars.nasa.domain}" = {
    serverAliases = [ "backups" ];
    forceSSL = true;
    sslCertificate = "/var/lib/nginx/certs/server.crt";
    sslCertificateKey = "/var/lib/nginx/certs/server.key";
    extraConfig = ''
      allow ${vars.nasa.lanSubnet};
      allow 100.64.0.0/10;
      allow 127.0.0.1;
      deny all;
    '';
    locations."/".proxyPass = "http://127.0.0.1:${toString port}";
  };
}
