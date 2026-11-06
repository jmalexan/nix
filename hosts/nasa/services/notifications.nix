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
  # Enable only after Apple identifiers and root-only credentials are provisioned.
  config = lib.mkIf cfg.enable {
    services.nginx.virtualHosts."notifications.${vars.nasa.domain}" = {
      forceSSL = true;
      sslCertificate = "/var/lib/nginx/certs/server.crt";
      sslCertificateKey = "/var/lib/nginx/certs/server.key";
      extraConfig = ''
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
