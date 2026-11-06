{ pkgs }:
let
  platform = import ../. { inherit pkgs; };
in
pkgs.testers.runNixOSTest {
  name = "approval-ssh-gate";
  # Also runnable in the development container, which has no /dev/kvm.
  requiredFeatures.kvm = false;
  nodes.machine = { lib, ... }: {
    imports = [ ../../../modules/approval-ssh-gate.nix ];
    virtualisation.memorySize = 1024;
    virtualisation.cores = 2;
    virtualisation.qemu.package = lib.mkForce pkgs.qemu;
    services.openssh.enable = true;
    services.openssh.settings.AuthorizedKeysFile = lib.mkForce "/run/test-normal-authorized-key";
    services.approvalSshGate = {
      enable = true;
      origin = "http://localhost:8092";
      credentialFile = "/run/test-gate-token";
    };
    # Exercise the same service with a shorter hard limit, avoiding a 15-minute test.
    systemd.services."approval-ssh-gate@".serviceConfig.RuntimeMaxSec = lib.mkForce 15;
    environment.systemPackages = [
      platform.python
      pkgs.openssh
      pkgs.procps
    ];
    systemd.services.test-approvals = {
      wantedBy = [ "multi-user.target" ];
      environment = {
        PYTHONPATH = "${../backend}";
        MICROAPP_ORIGIN = "http://localhost:8092";
        MICROAPP_DATABASE = "/var/lib/test-approvals/state.sqlite";
        MICROAPP_REQUESTER_FILE = "/run/test-requester-token";
        MICROAPP_WORKER_FILE = "/run/test-worker-token";
        MICROAPP_ENROLLMENT_FILE = "/run/test-enrollment-token";
        MICROAPP_GATE_FILE = "/run/test-gate-token";
      };
      preStart = ''
        ${platform.python}/bin/python - <<'PY'
        import os
        from pathlib import Path
        os.umask(0o077)
        for name, letter in [('requester','r'),('worker','w'),('enrollment','e'),('gate','g')]:
            Path('/run/test-' + name + '-token').write_text(letter * 32)
        PY
      '';
      serviceConfig = {
        ExecStart = "${platform.python}/bin/uvicorn microapps.api:from_environment --factory --host 127.0.0.1 --port 8092";
        StateDirectory = "test-approvals";
      };
    };
  };
  testScript = ''
    machine.start()
    machine.wait_for_unit("sshd.service")
    machine.wait_for_unit("test-approvals.service")
    machine.wait_for_unit("approval-ssh-gate.socket")
    machine.wait_for_open_port(8092)
    machine.succeed("PYTHONPATH=${../backend} ${platform.python}/bin/python ${./gate_vm.py}", timeout=240)
  '';
}
