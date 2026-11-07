{ pkgs, ... }:
let
  platform = import ../../../apps/microapps { inherit pkgs; };
in
{
  imports = [ ../../../modules/microapp-accounts.nix ];
  services.microappAccounts = {
    enable = true;
    clients = [
      "microapp-approvals"
      "updates-dashboard"
    ];
  };
  services.restic.backups.backblaze.paths = [ "/var/lib/microapp-secrets/accounts/enrollment" ];
  systemd.services.microapp-accounts-backup = {
    description = "Consistent shared owner account backup";
    after = [ "microapp-accounts.service" ];
    requires = [ "microapp-accounts.service" ];
    serviceConfig.Type = "oneshot";
    unitConfig.AssertPathIsMountPoint = "/Data/smb";
    script = ''
      install -d -m 0700 /Data/smb/Internal/Backups/microapps
      ${platform.python}/bin/python - <<'PY'
      import os, sqlite3, tempfile
      from pathlib import Path
      destination = Path('/Data/smb/Internal/Backups/microapps/accounts.sqlite')
      fd, temporary = tempfile.mkstemp(dir=destination.parent, prefix='.accounts-')
      os.close(fd)
      try:
          with sqlite3.connect('file:/var/lib/microapp-accounts/state.sqlite?mode=ro', uri=True) as source:
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
    requires = [ "microapp-accounts-backup.service" ];
    after = [ "microapp-accounts-backup.service" ];
  };
}
