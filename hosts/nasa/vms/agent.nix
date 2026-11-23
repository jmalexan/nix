{
  config,
  lib,
  pkgs,
  pkgs-unstable,
  claude-code-pkg,
  home-manager-stable,
  rex,
  vars,
  ...
}:
let
  agentWorkSource = "/Data/smb/Agent Workspace";
  agentWorkUid = 1000;
in
{
  imports = [ ../../../modules/agent-network.nix ];
  services.agentNetwork.enable = true;
  services.journald.extraConfig = "Storage=persistent";
  microvm.vms.robots = {
    pkgs = null;
    specialArgs = {
      gitBrokerEnabled = config.services.gitBroker.enable;
      nasaJournalSource = "/var/log/journal";
      inherit
        agentWorkSource
        agentWorkUid
        pkgs-unstable
        claude-code-pkg
        home-manager-stable
        rex
        vars
        ;
    };
    config = import ./agent-guest.nix;
  };
  systemd.services.agent-workspace-directory = {
    description = "Prepare the Agent Workspace folder on the mounted Data pool";
    requires = [ "zfs-mount.service" ];
    after = [ "zfs-mount.service" ];
    unitConfig.AssertPathIsMountPoint = "/Data/smb";
    serviceConfig.Type = "oneshot";
    script = ''
      # VirtioFS preserves numeric ownership across NASA and robots.
      test "$(id -u ${vars.user.name})" = ${toString agentWorkUid}
      test ! -L ${lib.escapeShellArg agentWorkSource}
      install -d -m 0700 -o ${vars.user.name} -g root ${lib.escapeShellArg agentWorkSource}
    '';
  };
  systemd.services."microvm-virtiofsd@robots" = {
    requires = [ "agent-workspace-directory.service" ];
    after = [ "agent-workspace-directory.service" ];
  };
  # No bridged path into the trusted LAN. Assign the point-to-point address
  # after microvm creates the TAP, before the guest starts.
  systemd.services.agent-tap-address = {
    requires = [ "microvm-tap-interfaces@robots.service" ];
    after = [ "microvm-tap-interfaces@robots.service" ];
    before = [ "microvm@robots.service" ];
    partOf = [ "microvm@robots.service" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    script = ''
      ${pkgs.iproute2}/bin/ip address replace 10.200.201.1/30 dev agenttap0
      ${pkgs.iproute2}/bin/ip link set agenttap0 up
    '';
  };
  networking.networkmanager.unmanaged = [ "agenttap0" ];
  systemd.services."microvm@robots" = {
    requires = [
      "agent-boundary.service"
      "agent-tap-address.service"
    ]
    ++ lib.optional config.services.gitBroker.enable "git-broker-client-credential.service";
    after = [
      "agent-boundary.service"
      "agent-tap-address.service"
    ]
    ++ lib.optional config.services.gitBroker.enable "git-broker-client-credential.service";
    # QEMU needs read permission for the single read-only journal export.
    serviceConfig.SupplementaryGroups = [ "systemd-journal" ];
    serviceConfig.LoadCredential = [
      "agent-github:${config.age.secrets.agent-github.path}"
      "agent-requester:/var/lib/microapp-secrets/approvals/requester"
    ]
    ++ lib.optional config.services.gitBroker.enable "agent-git-broker:${config.services.gitBroker.clientTokenFile}";
  };
  age.secrets.agent-github.file = ../../../secrets/agent-github.age;
  systemd.services."microvm@robots".serviceConfig.UMask = "0077";
  environment.systemPackages = [
    (pkgs.writeShellApplication {
      name = "robots-health";
      runtimeInputs = [
        pkgs.systemd
        pkgs.coreutils
        pkgs.gnugrep
      ];
      text = ''
        for unit in agent-boundary.service microvm@robots.service; do
          systemctl is-active --quiet "$unit"
        done
        invocation=$(systemctl show microvm@robots.service --property=InvocationID --value)
        test -n "$invocation"
        for _attempt in $(seq 1 330); do
          records=$(journalctl --quiet --no-pager -o cat "_SYSTEMD_INVOCATION_ID=$invocation" | tr -d '\r')
          if grep -qx ROBOTS_READY <<< "$records"; then
            systemctl is-active --quiet microvm@robots.service
            test "$invocation" = "$(systemctl show microvm@robots.service --property=InvocationID --value)"
            grep '^ROBOTS_SSH_HOST_KEY ' <<< "$records" | tail -1
            echo 'robots: guest SSH, Rex, Tailscale, and scoped credentials are ready'
            exit 0
          fi
          sleep 2
        done
        echo 'robots did not report readiness; inspect microvm@robots.service logs' >&2
        exit 1
      '';
    })
  ];
  # Only the isolated guest source is added to app/gate allowlists.
  services.approvalSshGate.allowedPeers = [ "10.200.201.2/32" ];
  services.nginx.virtualHosts."approve.${vars.nasa.domain}".extraConfig = lib.mkBefore ''
    allow 10.200.201.2;
  '';
  services.nginx.virtualHosts."updates.${vars.nasa.domain}".extraConfig = lib.mkBefore ''
    allow 10.200.201.2;
  '';
}
