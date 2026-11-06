{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.services.approvalSshGate;
  platform = import ../apps/microapps { inherit pkgs; };
  sessionCommand = pkgs.writeShellScript "approval-ssh-session" ''
    set -eu
    printf started > "$1"
    exec ${pkgs.bash}/bin/bash -c "''${SSH_ORIGINAL_COMMAND:-}"
  '';
  sshConfig = pkgs.writeText "approval-sshd-config" ''
    HostKey ${cfg.hostKey}
    AllowUsers nasa-automation
    AuthenticationMethods publickey
    PubkeyAcceptedAlgorithms ssh-ed25519
    AuthorizedKeysFile none
    TrustedUserCAKeys none
    PasswordAuthentication no
    KbdInteractiveAuthentication no
    HostbasedAuthentication no
    PermitEmptyPasswords no
    PermitRootLogin no
    UsePAM no
    StrictModes yes
    DisableForwarding yes
    PermitTunnel no
    PermitTTY no
    PermitUserRC no
    PermitUserEnvironment no
    MaxSessions 1
    MaxAuthTries 2
    LoginGraceTime 10
    ClientAliveInterval 15
    ClientAliveCountMax 2
    UseDNS no
    PrintMotd no
    PidFile none
    LogLevel ERROR
  '';
in
{
  options.services.approvalSshGate = {
    enable = lib.mkEnableOption "one-connection, phone-approved SSH access";
    origin = lib.mkOption { type = lib.types.str; };
    credentialFile = lib.mkOption { type = lib.types.str; };
    hostKey = lib.mkOption {
      type = lib.types.str;
      default = "/etc/ssh/ssh_host_ed25519_key";
    };
    listenAddress = lib.mkOption {
      type = lib.types.str;
      default = "127.0.0.1";
      description = "Private IPv4 address for the gate; no firewall port is opened.";
    };
    allowedPeers = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ "127.0.0.1/32" ];
      description = "IPv4/IPv6 source networks allowed to present request IDs.";
    };
    port = lib.mkOption {
      type = lib.types.port;
      default = 2222;
    };
  };
  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = config.services.openssh.enable;
        message = "The approval gate requires the host OpenSSH service to provision its privilege-separation account and host key.";
      }
    ];
    users.groups.nasa-automation = { };
    users.users.nasa-automation = {
      isSystemUser = true;
      group = "nasa-automation";
      home = "/var/empty";
      createHome = false;
      shell = pkgs.bashInteractive;
      # Invalid password hash, but not Linux's '!' account-lock marker:
      # sshd without PAM must be able to check public-key authentication.
      hashedPassword = "*";
    };
    # The gate is the only SSH listener allowed to admit this account.
    services.openssh.settings.DenyUsers = [ "nasa-automation" ];

    systemd.sockets.approval-ssh-gate = {
      description = "Phone-approved NASA SSH entry point";
      wantedBy = [ "sockets.target" ];
      listenStreams = [ "${cfg.listenAddress}:${toString cfg.port}" ];
      socketConfig = {
        Accept = true;
        MaxConnections = 1;
        MaxConnectionsPerSource = 1;
      };
    };
    systemd.services."approval-ssh-gate@" = {
      description = "One approved NASA connection";
      # Stop all instances if the listener is stopped during maintenance.
      bindsTo = [ "approval-ssh-gate.socket" ];
      after = [ "approval-ssh-gate.socket" ];
      environment = {
        PYTHONPATH = "${../apps/microapps/backend}";
        GATE_ORIGIN = cfg.origin;
        GATE_CREDENTIAL = "%d/gate";
        GATE_FINISH_CREDENTIAL = cfg.credentialFile;
        GATE_SSHD = "${pkgs.openssh}/bin/sshd";
        GATE_SSHD_CONFIG = "${sshConfig}";
        GATE_SESSION_COMMAND = "${sessionCommand}";
        GATE_ALLOWED_PEERS = lib.concatStringsSep "," cfg.allowedPeers;
      };
      path = [
        pkgs.coreutils
        pkgs.bash
        pkgs.procps
      ];
      serviceConfig = {
        Type = "exec";
        ExecStart = "${platform.python}/bin/python -m microapps.gate";
        ExecStopPost = "${platform.python}/bin/python -m microapps.gate finish";
        StandardInput = "socket";
        StandardOutput = "socket";
        StandardError = "journal";
        LoadCredential = [ "gate:${cfg.credentialFile}" ];
        RuntimeDirectory = "approval-ssh-gate-%i";
        RuntimeDirectoryMode = "0755";
        RuntimeMaxSec = 900;
        # A credential timeout is insufficient: kill the entire process tree.
        KillMode = "control-group";
        KillSignal = "SIGKILL";
        SendSIGKILL = true;
        TimeoutStopSec = "15s";
        Restart = "no";
        UMask = "0077";
        NoNewPrivileges = true;
        PrivateTmp = true;
        PrivateDevices = true;
        PrivateIPC = true;
        ProtectSystem = "strict";
        ProtectHome = "read-only";
        ProtectControlGroups = true;
        ProtectKernelTunables = true;
        ProtectKernelModules = true;
        ProtectKernelLogs = true;
        RestrictSUIDSGID = true;
        RestrictNamespaces = true;
        RestrictRealtime = true;
        ProtectProc = "invisible";
        TemporaryFileSystem = "/dev/shm:rw,nosuid,nodev,noexec";
        InaccessiblePaths = [
          "-/run/dbus/system_bus_socket"
          "-/run/systemd/private"
          "-/run/user"
          "-/run/docker.sock"
          "-/run/containerd"
          "-/nix/var/nix/daemon-socket"
        ];
        TasksMax = 128;
        MemoryMax = "512M";
      };
    };
  };
}
