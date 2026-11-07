{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.services.microappAccounts;
  platform = import ../apps/microapps { inherit pkgs; };
  socket = "/run/microapp-accounts.sock";
  enrollment = "/var/lib/microapp-secrets/accounts/enrollment";
in
{
  options.services.microappAccounts = {
    enable = lib.mkEnableOption "the shared microapp owner account";
    clients = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = "Systemd services permitted to verify the owner password over the private Unix socket.";
    };
  };
  config = lib.mkIf cfg.enable {
    users.groups.microapp-account-clients = { };
    environment.systemPackages = [ platform.authAdmin ];
    systemd.sockets.microapp-accounts = {
      wantedBy = [ "sockets.target" ];
      socketConfig = {
        ListenStream = socket;
        SocketMode = "0660";
        SocketGroup = "microapp-account-clients";
        RemoveOnStop = true;
      };
    };
    systemd.services = {
      microapp-account-credentials = {
        description = "Provision shared owner account setup credential";
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
          UMask = "0077";
        };
        environment.PYTHONPATH = "${../apps/microapps/backend}";
        script = "${platform.python}/bin/python -m microapps.auth_admin provision --token-file ${enrollment}";
      };
      microapp-accounts = {
        description = "Shared microapp owner account";
        requires = [
          "microapp-accounts.socket"
          "microapp-account-credentials.service"
        ];
        after = [
          "microapp-accounts.socket"
          "microapp-account-credentials.service"
        ];
        stopIfChanged = false;
        environment = {
          PYTHONPATH = "${../apps/microapps/backend}";
          MICROAPP_ACCOUNT_DATABASE = "/var/lib/microapp-accounts/state.sqlite";
          MICROAPP_ACCOUNT_ENROLLMENT_FILE = "%d/enrollment";
        };
        serviceConfig = {
          Type = "notify";
          TimeoutStartSec = 30;
          ExecStart = "${platform.python}/bin/python -m uvicorn microapps.accounts:from_environment --factory --fd 3 --no-access-log";
          DynamicUser = true;
          User = "microapp-accounts";
          StateDirectory = "microapp-accounts";
          StateDirectoryMode = "0700";
          LoadCredential = [ "enrollment:${enrollment}" ];
          UMask = "0077";
          Restart = "on-failure";
          NoNewPrivileges = true;
          PrivateTmp = true;
          ProtectSystem = "strict";
          ProtectHome = true;
          ProtectKernelTunables = true;
          ProtectControlGroups = true;
          RestrictSUIDSGID = true;
          CapabilityBoundingSet = "";
          RestrictAddressFamilies = [ "AF_UNIX" ];
        };
      };
    }
    // lib.genAttrs cfg.clients (_: {
      wants = [ "microapp-accounts.socket" ];
      after = [ "microapp-accounts.socket" ];
      environment.MICROAPP_ACCOUNT_SOCKET = socket;
      serviceConfig.SupplementaryGroups = [ "microapp-account-clients" ];
    });
  };
}
