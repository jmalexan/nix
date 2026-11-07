{ pkgs }:
pkgs.testers.runNixOSTest {
  name = "robots-disk-backup";
  requiredFeatures.kvm = false;
  nodes.machine = { lib, ... }: {
    imports = [
      (import ../hosts/nasa/services/backup/robots.nix {
        dataset = "testpool/vms";
        mountPoint = "/vm-data";
        stateDir = "/vm-data/robots";
      })
    ];
    virtualisation.memorySize = 1536;
    virtualisation.emptyDiskImages = [ 512 ];
    virtualisation.qemu.package = lib.mkForce pkgs.qemu;
    networking.hostId = "a1234567";
    boot.zfs.forceImportRoot = false;
    boot.supportedFilesystems = [ "zfs" ];
    boot.zfs.devNodes = "/dev/disk/by-uuid";
    services.restic.backups.backblaze = {
      repository = "/backup-repository";
      passwordFile = toString (pkgs.writeText "test-restic-password" "test-only");
      initialize = true;
      timerConfig = null;
    };
    systemd.services."microvm@robots".serviceConfig.ExecStart = "${pkgs.coreutils}/bin/sleep infinity";
    environment.systemPackages = [
      pkgs.restic
      pkgs.e2fsprogs
      pkgs.jq
    ];
  };
  testScript = ''
    machine.start()
    machine.wait_for_unit("multi-user.target")
    machine.succeed("zpool create -f -m none testpool /dev/vdb; zfs create -o mountpoint=/vm-data testpool/vms")
    machine.succeed("mkdir -p /vm-data/robots /mnt/disk; truncate -s 64M /vm-data/robots/root.img; mkfs.ext4 -q -F /vm-data/robots/root.img; mount -o loop /vm-data/robots/root.img /mnt/disk")
    machine.succeed("echo persisted-agent-work > /mnt/disk/work.txt; sync")
    machine.succeed("systemctl start microvm@robots")
    invocation = machine.succeed("systemctl show microvm@robots -p InvocationID --value")
    machine.succeed("systemctl start restic-backups-backblaze", timeout=180)
    assert machine.succeed("systemctl show microvm@robots -p InvocationID --value") == invocation
    machine.succeed("systemctl is-active microvm@robots")
    machine.fail("zfs list -t snapshot testpool/vms@restic-robots")
    # Change the live image, then recover the earlier ext4 image from Restic.
    machine.succeed("echo later-work > /mnt/disk/work.txt; sync")
    restic = "restic -r /backup-repository --password-file=${pkgs.writeText "test-restic-password" "test-only"}"
    machine.succeed(restic + " restore latest --sparse --target /restore", timeout=180)
    restored = "/restore/vm-data/.zfs/snapshot/restic-robots/robots"
    machine.succeed("jq -r .consistency " + restored + "/backup-metadata.json | grep -Fx power-loss")
    machine.succeed("status=0; e2fsck -p " + restored + "/root.img || status=$?; test $status -le 1")
    machine.succeed("mkdir /mnt/restored; mount -o loop,ro " + restored + "/root.img /mnt/restored; grep -Fx persisted-agent-work /mnt/restored/work.txt")
    machine.succeed("umount /mnt/restored /mnt/disk")
    # Never publish a successful backup with a missing disk.
    before = machine.succeed(restic + " snapshots --json")
    machine.succeed("mv /vm-data/robots/root.img /vm-data/robots/saved.img")
    machine.fail("systemctl start restic-backups-backblaze")
    assert machine.succeed(restic + " snapshots --json") == before
    machine.fail("zfs list -t snapshot testpool/vms@restic-robots")
    machine.succeed("mv /vm-data/robots/saved.img /vm-data/robots/root.img")
    # Recover our own leftover snapshot, but never destroy an unrelated one.
    machine.succeed("zfs snapshot -o org.jmalexan:backup=robots-restic testpool/vms@restic-robots; systemctl start restic-backups-backblaze", timeout=180)
    machine.fail("zfs list -t snapshot testpool/vms@restic-robots")
    machine.succeed("zfs snapshot testpool/vms@restic-robots")
    machine.fail("systemctl start restic-backups-backblaze")
    machine.succeed("zfs list -t snapshot testpool/vms@restic-robots; zfs destroy testpool/vms@restic-robots")
    # ExecStopPost cleans the snapshot even if Restic fails after preparation.
    machine.succeed("mv /backup-repository /saved-repository; touch /backup-repository")
    machine.fail("systemctl start restic-backups-backblaze")
    machine.fail("zfs list -t snapshot testpool/vms@restic-robots")
  '';
}
