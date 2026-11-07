{
  config,
  lib,
  vars,
  pkgs,
  ...
}:
let
  cfg = config.services.notificationBridge;
  platform = import ../../../apps/notifications { inherit pkgs; };
in
{
  imports = [ ../../../modules/notification-bridge.nix ];
  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = !config.services.open-webui.enable || cfg.port != config.services.open-webui.port;
        message = "Notification bridge and Open WebUI must use different listening ports";
      }
    ];
    age.secrets.notifications-apns.file = ../../../secrets/notifications-apns.age;
    systemd.services.notification-publisher-credentials = {
      description = "Provision the local notification publisher credential";
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        UMask = "0077";
      };
      environment.PYTHONPATH = "${../../../apps/notifications/backend}";
      script = ''
        ${platform.python}/bin/python -m notifications.bootstrap \
          --registry ${lib.escapeShellArg cfg.servicesFile} \
          --publisher ${lib.escapeShellArg config.services.approvals.notifications.tokenFile} \
          --origin ${lib.escapeShellArg "https://approve.${vars.nasa.domain}"} \
          --additional-origin https://approve
      '';
    };
    systemd.services.microapp-notifications = {
      environment = {
        NOTIFICATIONS_ALIASES = "https://notifications";
        NOTIFICATIONS_LINK_ORIGIN = "https://notifications";
      };
      requires = [ "notification-publisher-credentials.service" ];
      after = [ "notification-publisher-credentials.service" ];
    };
    systemd.services.microapp-approvals-bridge-notify =
      lib.mkIf config.services.approvals.notifications.enable
        {
          requires = [ "notification-publisher-credentials.service" ];
          after = [ "notification-publisher-credentials.service" ];
        };
    services.restic.backups.backblaze.paths = [
      cfg.servicesFile
      config.services.approvals.notifications.tokenFile
    ];
    services.nginx.virtualHosts."notifications.${vars.nasa.domain}" = {
      serverAliases = [ "notifications" ];
      forceSSL = true;
      sslCertificate = "/var/lib/nginx/certs/server.crt";
      sslCertificateKey = "/var/lib/nginx/certs/server.key";
      extraConfig = ''
        allow 10.200.201.2;
        allow ${vars.nasa.lanSubnet};
        allow 100.64.0.0/10;
        allow 127.0.0.1;
        deny all;
        client_max_body_size 16k;
      '';
      locations."/".proxyPass = "http://127.0.0.1:${toString cfg.port}";
    };
    systemd.services.microapp-notifications-backup = {
      description = "Consistent notification database backup";
      after = [ "microapp-notifications.service" ];
      requires = [ "microapp-notifications.service" ];
      serviceConfig.Type = "oneshot";
      unitConfig.AssertPathIsMountPoint = "/Data/smb";
      script = ''
        install -d -m 0700 /Data/smb/Internal/Backups/microapps
        ${platform.python}/bin/python - <<'PY'
        import os, sqlite3, tempfile
        from pathlib import Path
        destination = Path('/Data/smb/Internal/Backups/microapps/notifications.sqlite')
        fd, temporary = tempfile.mkstemp(dir=destination.parent, prefix='.notifications-')
        os.close(fd)
        try:
            with sqlite3.connect('/var/lib/microapp-notifications/state.sqlite') as source:
                with sqlite3.connect(temporary) as target:
                    source.backup(target)
            os.replace(temporary, destination)
        finally:
            if os.path.exists(temporary):
                os.unlink(temporary)
        PY
      '';
    };
    systemd.services.database-backup = {
      requires = [ "microapp-notifications-backup.service" ];
      after = [ "microapp-notifications-backup.service" ];
    };
  };
}
