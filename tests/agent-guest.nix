{
  pkgs,
  nixpkgs,
  microvm,
  specialArgs,
}:
let
  guest = import "${nixpkgs}/nixos/lib/eval-config.nix" {
    system = "x86_64-linux";
    specialArgs = specialArgs // {
      gitBrokerEnabled = true;
      nasaJournalSource = "nasa-journal";
    };
    modules = [
      microvm.nixosModules.microvm
      ../hosts/nasa/vms/agent-guest.nix
      ({ config, lib, ... }: {
        imports = [ ../modules/git-broker.nix ];
        services.gitBroker = {
          enable = true;
          repositories.project = {
            github = "owner/project";
            write_prefixes = [ "robot/" ];
          };
          clientTokenFile = toString (
            pkgs.writeText "test-broker-client" (lib.concatStrings (lib.replicate 64 "c"))
          );
          upstreamTokenFile = toString (
            pkgs.writeText "test-broker-upstream" (lib.concatStrings (lib.replicate 64 "u"))
          );
          approvalTokenFile = toString (
            pkgs.writeText "test-broker-approval" (lib.concatStrings (lib.replicate 64 "a"))
          );
        };
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
            agent-git-broker = pkgs.writeText "fake-broker-client" "test-only-broker-client";
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
          unitConfig.RequiresMountsFor = [ "/var/log/nasa-journal" ];
          unitConfig.OnFailure = "poweroff.target";
          requires = [
            "agent-github-identity.service"
            "nix-daemon.service"
            "sshd.service"
            "tailscaled-set.service"
            "dev-zram0.swap"
          ];
          after = [
            "git-broker.service"
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
            pkgs.curl
          ];
          script = ''
            set -x
            systemctl is-active --quiet git-broker.service || {
              journalctl -u git-broker.service -n 50 --no-pager -o cat
              exit 1
            }
            curl --fail --silent --retry 30 --retry-connrefused --retry-delay 1 --max-time 2 http://127.0.0.1:${toString config.services.gitBroker.port}/health | grep -F '"status":"ok"'
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
            test "$(cat /home/robot/.local/share/git-broker/token)" = test-only-broker-client
            test "$(stat -c '%a:%U' /home/robot/.local/share/git-broker/token)" = 600:robot
            runuser -u robot -- /run/current-system/sw/bin/git-broker --help >/dev/null
            runuser -u robot -- /run/current-system/sw/bin/nasa-approved-access --dry-run --reason 'Packaged access client check' -- true | grep -F 'nasa-automation'
            test "$(cat /home/robot/.local/share/nasa-github-app/private-key.pem)" = test-only-github-key
            test "$(stat -c '%a:%U' /home/robot/.local/share/nasa-github-app/private-key.pem)" = 600:robot
            test "$(id -nG robot)" = "users systemd-journal"
            runuser -u robot -- /run/current-system/sw/bin/nasa-journalctl -u fixture.service --no-pager -o cat | grep -Fx NASA_JOURNAL_FIXTURE
            if touch /var/log/nasa-journal/guest-write; then exit 1; fi
            # Even guest root cannot make QEMU's read-only export writable.
            mount -o remount,rw /var/log/nasa-journal || true
            if touch /var/log/nasa-journal/guest-write; then exit 1; fi
            mount -o remount,ro /var/log/nasa-journal
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
  mkdir nasa-journal
  cat > fixture.export <<'EOF'
  __REALTIME_TIMESTAMP=1794051000000000
  __MONOTONIC_TIMESTAMP=1
  _BOOT_ID=11111111111111111111111111111111
  _MACHINE_ID=22222222222222222222222222222222
  _SYSTEMD_UNIT=fixture.service
  MESSAGE=NASA_JOURNAL_FIXTURE

  EOF
  ${pkgs.systemd}/lib/systemd/systemd-journal-remote --output=nasa-journal/fixture.journal --split-mode=none fixture.export
  chmod 755 nasa-journal
  chmod 644 nasa-journal/fixture.journal
  for boot in FIRST SECOND; do
    timeout 180 ${guest.config.microvm.declaredRunner}/bin/microvm-run 2>&1 | tr -d '\r' | tee "$boot.log"
    grep -q "AGENT_TEST_''${boot}_BOOT_OK" "$boot.log" || { cat "$boot.log"; exit 1; }
  done
  mkdir -p "$out"
  cp FIRST.log SECOND.log "$out/"
''
