# Back up a stable view of the raw VM disk without stopping the guest.
{
  dataset,
  mountPoint,
  stateDir ? "/var/lib/microvms/robots",
}:
{ lib, pkgs, ... }:
let
  snapshot = "${dataset}@restic-robots";
  relativeDir = lib.removePrefix (if mountPoint == "/" then "/" else "${mountPoint}/") stateDir;
  snapshotDir = "${lib.removeSuffix "/" mountPoint}/.zfs/snapshot/restic-robots/${relativeDir}";
  lifecycle = pkgs.writeShellApplication {
    name = "robots-backup-snapshot";
    runtimeInputs = [
      pkgs.zfs
      pkgs.coreutils
      pkgs.util-linux
      pkgs.jq
    ];
    text = ''
      snapshot=${lib.escapeShellArg snapshot}
      state_dir=${lib.escapeShellArg stateDir}
      cleanup() {
        if zfs list -H -t snapshot -o name "$snapshot" >/dev/null 2>&1; then
          if test "$(zfs get -H -o value org.jmalexan:backup "$snapshot")" != robots-restic; then
            echo "Refusing to destroy a snapshot not owned by robots backup" >&2
            return 1
          fi
          zfs destroy "$snapshot"
        fi
      }
      case "''${1:-}" in
        prepare)
          test -f "$state_dir/root.img"
          test ! -L "$state_dir/root.img"
          test "$(findmnt -n -o FSTYPE --target "$state_dir/root.img")" = zfs
          test "$(findmnt -n -o SOURCE --target "$state_dir/root.img")" = ${lib.escapeShellArg dataset}
          test "$(findmnt -n -o TARGET --target "$state_dir/root.img")" = ${lib.escapeShellArg mountPoint}
          cleanup
          # Metadata and disk are captured together in the same ZFS snapshot.
          temporary=$(mktemp "$state_dir/.backup-metadata.XXXXXX")
          trap 'rm -f "$temporary"' EXIT
          jq -n --arg created "$(date --utc --iso-8601=seconds)" \
            --arg host_system "$(readlink -f /run/current-system)" \
            --arg booted_runner "$(readlink -f "$state_dir/booted" || true)" \
            --arg guest_system "$(readlink -f "$state_dir/toplevel" || true)" \
            '{created: $created, consistency: "power-loss", host_system: $host_system,
              booted_runner: $booted_runner, guest_system: $guest_system}' > "$temporary"
          chmod 0600 "$temporary"
          mv -f "$temporary" "$state_dir/backup-metadata.json"
          trap - EXIT
          zfs snapshot -o org.jmalexan:backup=robots-restic "$snapshot"
          test -f ${lib.escapeShellArg "${snapshotDir}/root.img"}
          ;;
        cleanup) cleanup ;;
        *) echo 'Expected prepare or cleanup' >&2; exit 2 ;;
      esac
    '';
  };
in
{
  assertions = [
    {
      assertion = lib.hasPrefix (if mountPoint == "/" then "/" else "${mountPoint}/") stateDir;
      message = "The robots disk must be inside its backup dataset mount.";
    }
  ];
  services.restic.backups.backblaze = {
    paths = [
      "${snapshotDir}/root.img"
      "${snapshotDir}/backup-metadata.json"
    ];
    backupPrepareCommand = ''
      #!${pkgs.runtimeShell}
      exec ${lifecycle}/bin/robots-backup-snapshot prepare
    '';
    # Restic's module runs this from ExecStopPost, including failed backups.
    backupCleanupCommand = ''
      #!${pkgs.runtimeShell}
      exec ${lifecycle}/bin/robots-backup-snapshot cleanup
    '';
  };
}
