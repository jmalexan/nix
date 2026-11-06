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
          };
        };
        services.journald.extraConfig = "ForwardToConsole=yes";
        boot.kernelParams = [
          "systemd.log_target=console"
          "systemd.show_status=yes"
        ];
        # Run the real daemon/settings unit to catch unsupported flags. With no
        # guest network interfaces or auth key, no enrollment/network is involved.
        systemd.services.agent-tailscale-ready.enable = false;
        systemd.services.agent-ready.enable = false;
        services.rex.loginServer.enable = lib.mkForce false;
        systemd.services.agent-boot-test = {
          wantedBy = [ "multi-user.target" ];
          unitConfig.OnFailure = "poweroff.target";
          requires = [
            "agent-github-identity.service"
            "nix-daemon.service"
            "sshd.service"
            "tailscaled-set.service"
            "dev-zram0.swap"
          ];
          after = [
            "agent-github-identity.service"
            "nix-daemon.service"
            "sshd.service"
            "tailscaled-set.service"
            "dev-zram0.swap"
          ];
          serviceConfig = {
            Type = "oneshot";
          };
          path = [
            pkgs.nix
            pkgs.util-linux
            pkgs.coreutils
            pkgs.diffutils
            pkgs.openssh
            pkgs.kmod
          ];
          script = ''
            set -x
            cmp /home/robot/.codex/AGENTS.md /etc/robot/AGENTS.md
            cmp /home/robot/.claude/CLAUDE.md /etc/robot/AGENTS.md
            test -s /etc/robot/systems.md
            test -s /etc/robot/repositories.json
            test -d /home/robot/dev
            # Check negotiation with the real QEMU device. Virtio exposes
            # negotiated feature bits least-significant first; bit 5 is
            # VIRTIO_BALLOON_F_REPORTING (free-page reporting).
            modprobe virtio_balloon
            balloon_reporting=false
            for _attempt in $(seq 1 50); do
              for device in /sys/bus/virtio/drivers/virtio_balloon/virtio*; do
                if test -r "$device/features" && test "$(cut -c 6 "$device/features")" = 1; then
                  balloon_reporting=true
                fi
              done
              if "$balloon_reporting"; then break; fi
              sleep 0.1
            done
            "$balloon_reporting"
            # Check the real device on both boots, not just the Nix option.
            test "$(cat /sys/block/zram0/disksize)" -gt 0
            swapon --show=NAME --noheadings | grep -Fx /dev/zram0
            test ! -e /run/credentials/@system/agent-tailscale
            systemctl is-active --quiet tailscaled.service
            test "$(systemctl show tailscaled-set.service -p Result --value)" = success
            ssh-keygen -F 10.0.1.10 -f /etc/ssh/ssh_known_hosts | grep -F 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAII8xM12gVZXzdvRDHwXwP9kIxj5fecxG5gU39rSTxUXr'
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
