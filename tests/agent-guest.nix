{
  pkgs,
  nixpkgs,
  microvm,
  specialArgs,
}:
let
  guest = import "${nixpkgs}/nixos/lib/eval-config.nix" {
    system = "x86_64-linux";
    inherit specialArgs;
    modules = [
      microvm.nixosModules.microvm
      ../hosts/nasa/vms/agent-guest.nix
      ({ lib, ... }: {
        microvm = {
          cpu = "max";
          mem = lib.mkForce 1024;
          qemu.package = pkgs.qemu;
          interfaces = lib.mkForce [ ];
          volumes = lib.mkForce [
            {
              image = "root.img";
              mountPoint = "/";
              size = 4096;
            }
          ];
          credentialFiles = lib.mkForce {
            agent-requester = pkgs.writeText "fake-requester" "test-only-requester";
            agent-github = pkgs.writeText "fake-github-key" "test-only-github-key";
            agent-tailscale = pkgs.writeText "fake-tailscale-key" "test-only-tailscale-key";
          };
        };
        services.journald.extraConfig = "ForwardToConsole=yes";
        boot.kernelParams = [
          "systemd.log_target=console"
          "systemd.show_status=yes"
        ];
        # No real enrollment or external network is involved in a boot test.
        systemd.services.tailscaled-autoconnect.enable = false;
        services.tailscale.enable = lib.mkForce false;
        systemd.services.agent-ready.enable = false;
        services.rex.loginServer.enable = lib.mkForce false;
        systemd.services.agent-boot-test = {
          wantedBy = [ "multi-user.target" ];
          unitConfig.OnFailure = "poweroff.target";
          requires = [
            "agent-github-identity.service"
            "nix-daemon.service"
            "sshd.service"
          ];
          after = [
            "agent-github-identity.service"
            "nix-daemon.service"
            "sshd.service"
          ];
          serviceConfig = {
            Type = "oneshot";
            ImportCredential = "agent-tailscale";
          };
          path = [
            pkgs.nix
            pkgs.util-linux
            pkgs.coreutils
            pkgs.diffutils
            pkgs.openssh
          ];
          script = ''
            set -x
            cmp /home/robot/.codex/AGENTS.md /etc/robot/AGENTS.md
            cmp /home/robot/.claude/CLAUDE.md /etc/robot/AGENTS.md
            test -s /etc/robot/systems.md
            test -s /etc/robot/repositories.json
            test -d /home/robot/dev
            test "$(cat "$CREDENTIALS_DIRECTORY/agent-tailscale")" = test-only-tailscale-key
            test "$(cat /home/robot/.local/share/nasa-github-app/private-key.pem)" = test-only-github-key
            test "$(stat -c '%a:%U' /home/robot/.local/share/nasa-github-app/private-key.pem)" = 600:robot
            test "$(id -nG robot)" = users
            test ! -e /run/wrappers/bin/sudo
            sshd -T -f /etc/ssh/sshd_config > /run/test-sshd-config
            grep -i '^AllowAgentForwarding no$' /run/test-sshd-config
            test ! -e /home/robot/.ssh/id_ed25519
            test ! -e /home/robot/.config/gh/hosts.yml
            if test -f /home/robot/persisted-store-path; then
              runuser -u robot -- nix-store --verify-path "$(cat /home/robot/persisted-store-path)"
              test -s /etc/ssh/ssh_host_ed25519_key
              test "$(sha256sum /etc/ssh/ssh_host_ed25519_key)" = "$(cat /home/robot/host-key-hash)"
              echo AGENT_TEST_SECOND_BOOT_OK > /dev/ttyS0
            else
              runuser -u robot -- ${pkgs.runtimeShell} -c 'echo agent-owned-test > /home/robot/source; nix-store --add /home/robot/source > /home/robot/persisted-store-path'
              sha256sum /etc/ssh/ssh_host_ed25519_key > /home/robot/host-key-hash
              echo AGENT_TEST_FIRST_BOOT_OK > /dev/ttyS0
            fi
            systemctl poweroff --no-block
          '';
        };
      })
    ];
  };
in
pkgs.runCommand "agent-guest-boot" { nativeBuildInputs = [ pkgs.coreutils ]; } ''
  export HOME="$TMPDIR"
  set -o pipefail
  for boot in FIRST SECOND; do
    timeout 180 ${guest.config.microvm.declaredRunner}/bin/microvm-run 2>&1 | tr -d '\r' | tee "$boot.log"
    grep -q "AGENT_TEST_''${boot}_BOOT_OK" "$boot.log" || { cat "$boot.log"; exit 1; }
  done
  mkdir -p "$out"
  cp FIRST.log SECOND.log "$out/"
''
