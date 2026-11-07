{
  config,
  lib,
  pkgs,
  vars,
  ...
}:
let
  cfg = config.services.approvals;
  platform = import ../../../apps/microapps { inherit pkgs; };
in
{
  imports = [
    ../../../modules/microapps.nix
    ../../../modules/approval-ssh-gate.nix
  ];
  options.services.approvals = {
    enable = lib.mkEnableOption "the approval micro app";
    sshGate.enable = lib.mkEnableOption "the reviewed NASA connection gate";
    notifications = {
      enable = lib.mkEnableOption "generic native notification delivery alongside Web Push";
      origin = lib.mkOption {
        type = lib.types.str;
        default = "https://notifications.${vars.nasa.domain}";
      };
      recipient = lib.mkOption {
        type = lib.types.str;
        default = "owner";
      };
      tokenFile = lib.mkOption {
        type = lib.types.str;
        default = "/var/lib/microapp-secrets/approvals/notifications";
      };
    };
    vapidPublicKey = lib.mkOption {
      type = lib.types.str;
      default = "";
      description = "Public Web Push key; empty disables notifications.";
    };
  };
  config = lib.mkIf cfg.enable {
    services.approvalSshGate = lib.mkIf cfg.sshGate.enable {
      enable = true;
      origin = "https://approve.${vars.nasa.domain}";
      credentialFile = "/var/lib/microapp-secrets/approvals/gate";
      listenAddress = "10.0.1.10";
      allowedPeers = [ "10.0.1.0/24" ];
    };
    systemd.services.microapp-approvals-backup = {
      description = "Consistent approval database backup";
      after = [ "microapp-approvals.service" ];
      requires = [ "microapp-approvals.service" ];
      serviceConfig.Type = "oneshot";
      unitConfig.AssertPathIsMountPoint = "/Data/smb";
      script = ''
        install -d -m 0700 /Data/smb/Internal/Backups/microapps
        ${platform.python}/bin/python - <<'PY'
        import os, sqlite3, tempfile
        from pathlib import Path
        destination = Path('/Data/smb/Internal/Backups/microapps/approvals.sqlite')
        fd, temporary = tempfile.mkstemp(dir=destination.parent, prefix='.approvals-')
        os.close(fd)
        try:
            with sqlite3.connect('/var/lib/microapp-approvals/state.sqlite') as source:
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
      requires = [ "microapp-approvals-backup.service" ];
      after = [ "microapp-approvals-backup.service" ];
    };
    systemd.services.microapp-approvals = lib.mkIf config.services.gitBroker.enable {
      requires = [ "git-broker-client-credential.service" ];
      after = [ "git-broker-client-credential.service" ];
    };
    services.microapps.apps.approvals = {
      enable = true;
      package = platform.server;
      port = 8092;
      credentials = {
        requester = "/var/lib/microapp-secrets/approvals/requester";
        worker = "/var/lib/microapp-secrets/approvals/worker";
        enrollment = "/var/lib/microapp-secrets/approvals/enrollment";
      }
      // lib.optionalAttrs cfg.sshGate.enable {
        gate = "/var/lib/microapp-secrets/approvals/gate";
      }
      // lib.optionalAttrs config.services.gitBroker.enable {
        git-broker = config.services.gitBroker.approvalTokenFile;
      };
      environment = {
        MICROAPP_ORIGIN = "https://approve.${vars.nasa.domain}";
        MICROAPP_DATABASE = "/var/lib/microapp-approvals/state.sqlite";
        MICROAPP_REQUESTER_FILE = "%d/requester";
        MICROAPP_WORKER_FILE = "%d/worker";
        MICROAPP_ENROLLMENT_FILE = "%d/enrollment";
        MICROAPP_VAPID_PUBLIC = cfg.vapidPublicKey;
        MICROAPP_NOTIFICATION_BRIDGE = if cfg.notifications.enable then "1" else "0";
      }
      // lib.optionalAttrs cfg.sshGate.enable {
        MICROAPP_GATE_FILE = "%d/gate";
      }
      // lib.optionalAttrs config.services.gitBroker.enable {
        MICROAPP_GIT_BROKER_FILE = "%d/git-broker";
      };
    };
    systemd.services.microapp-approvals-notify = lib.mkIf (cfg.vapidPublicKey != "") {
      description = "Deliver approval Web Push notifications";
      after = [ "microapp-approvals.service" ];
      requires = [ "microapp-approvals.service" ];
      environment = {
        PYTHONPATH = "${../../../apps/microapps/backend}";
        MICROAPP_DATABASE = "/var/lib/microapp-approvals/state.sqlite";
        MICROAPP_VAPID_PRIVATE_FILE = "%d/vapid";
        MICROAPP_PUSH_SUBJECT = "mailto:${vars.user.email}";
      };
      serviceConfig = {
        Type = "oneshot";
        ExecStart = "${platform.python}/bin/python -m microapps.notify";
        User = "microapp-approvals";
        DynamicUser = true;
        StateDirectory = "microapp-approvals";
        StateDirectoryMode = "0700";
        LoadCredential = [ "vapid:/var/lib/microapp-secrets/approvals/vapid.pem" ];
        NoNewPrivileges = true;
        PrivateTmp = true;
        ProtectSystem = "strict";
        ProtectHome = true;
        UMask = "0077";
      };
    };
    systemd.timers.microapp-approvals-notify = lib.mkIf (cfg.vapidPublicKey != "") {
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnBootSec = "1min";
        OnUnitInactiveSec = "10s";
      };
    };
    systemd.services.microapp-approvals-bridge-notify = lib.mkIf cfg.notifications.enable {
      description = "Publish approval choices and apply notification responses";
      after = [ "microapp-approvals.service" ];
      requires = [ "microapp-approvals.service" ];
      environment = {
        PYTHONPATH = "${../../../apps/microapps/backend}";
        MICROAPP_DATABASE = "/var/lib/microapp-approvals/state.sqlite";
        MICROAPP_ORIGIN = "https://approve.${vars.nasa.domain}";
        NOTIFICATIONS_ORIGIN = cfg.notifications.origin;
        NOTIFICATIONS_RECIPIENT = cfg.notifications.recipient;
        NOTIFICATIONS_TOKEN_FILE = "%d/notifications";
      };
      serviceConfig = {
        Type = "oneshot";
        ExecStart = "${platform.python}/bin/python -m microapps.bridge_notify";
        DynamicUser = true;
        User = "microapp-approvals";
        StateDirectory = "microapp-approvals";
        StateDirectoryMode = "0700";
        LoadCredential = [ "notifications:${cfg.notifications.tokenFile}" ];
        NoNewPrivileges = true;
        PrivateTmp = true;
        ProtectSystem = "strict";
        ProtectHome = true;
        UMask = "0077";
      };
    };
    systemd.timers.microapp-approvals-bridge-notify = lib.mkIf cfg.notifications.enable {
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnBootSec = "30s";
        OnUnitInactiveSec = "10s";
      };
    };
  };
}
