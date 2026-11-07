# NAS backups and restore

The NAS writes database snapshots before the Backblaze restic job starts. The
`database-backup` unit requires `/Data/smb` to be mounted and atomically writes:

- `/Data/smb/Internal/Backups/databases/hass.dump`
- `/Data/smb/Internal/Backups/databases/immich.dump`

Home Assistant is dumped through the host PostgreSQL service. Immich is dumped
through its PostgreSQL container. The regular restic job then includes these
files with the rest of the protected data.

Check the most recent preparation and off-site backup with:

```console
systemctl status database-backup.service restic-backups-backblaze.service
journalctl -u database-backup.service -u restic-backups-backblaze.service
```

## Restore outline

1. Stop the application that owns the target database.
2. Restore the selected `.dump` file from restic to a temporary path.
3. Create or empty the target database as appropriate.
4. Restore with `pg_restore --clean --if-exists --no-owner` using the same
   PostgreSQL major version as the target. For Immich, run `pg_restore` inside
   the database container; for Home Assistant, run it as the host `postgres`
   user.
5. Start the application and verify migrations, logs, and representative data.

Always rehearse the exact commands against a disposable database first. A
successful backup job proves that bytes were stored, not that a particular
application release can restore them cleanly.

## Robots VM disk

The daily `restic-backups-backblaze` job includes the 64 GiB sparse robots disk
and `backup-metadata.json`, alongside the existing protected data. Immediately
before Restic runs, it creates `rpool/root@restic-robots` and reads only these
files from that immutable snapshot:

- `/.zfs/snapshot/restic-robots/var/lib/microvms/robots/root.img`
- `/.zfs/snapshot/restic-robots/var/lib/microvms/robots/backup-metadata.json`

The guest keeps running: no scheduled shutdown, reboot, or pause. This provides
power-loss consistency, not an application-quiesced backup. Guest memory,
unsaved editor buffers, and writes not yet sent to the disk are not captured;
the guest filesystem and applications recover their journals on restore.
The metadata records capture time, consistency, and the host/guest system and
booted runner paths. Immutable Nix boot assets are rebuilt from the repository;
this backs up the VM's persistent disk, not its running RAM or host Nix store.

Preparation verifies that the disk is actually on the expected ZFS dataset.
A missing disk or failed snapshot fails the backup rather than silently omitting
robots. ExecStopPost removes the temporary snapshot after success or failure.
A marked leftover from a host crash is removed before the next attempt; snapshots
without the backup ownership property are never deleted. The temporary root
snapshot retains changed root-dataset blocks until the backup completes.

The disk contains source, logins, and other private state. It uses the existing
encrypted Restic repository, credentials, daily schedule, and retention policy
(14 daily, 8 weekly, 12 monthly). Restic deduplicates unchanged content; scanning
the raw disk still adds backup time. No backup credential is delivered to robots.

After deployment, verify the first real off-site backup (deployment alone does
not create one):

```sh
nasa-journalctl -u restic-backups-backblaze --since today --no-pager -n 100
```

From an authorized NASA administrator terminal:

```sh
sudo restic-backblaze snapshots --path /.zfs/snapshot/restic-robots/var/lib/microvms/robots/root.img
sudo restic-backblaze ls SNAPSHOT_ID /.zfs/snapshot/restic-robots/var/lib/microvms/robots
```

### Disk restore

Use a specific snapshot ID that contains the disk, rather than an unqualified
`latest`. Stop robots before replacing its disk. Keep the current disk for
rollback, and do not boot the restored identity beside a running original.

1. Restore the disk and metadata to a separate directory. `--sparse` is needed
   to preserve holes rather than allocating the full logical image size:

   ```sh
   sudo restic-backblaze restore SNAPSHOT_ID --sparse --target /var/lib/robots-restore \
     --include /.zfs/snapshot/restic-robots/var/lib/microvms/robots/root.img \
     --include /.zfs/snapshot/restic-robots/var/lib/microvms/robots/backup-metadata.json
   ```

2. Inspect the metadata and provision the matching or compatible declared guest
   configuration. Preserve the host's existing scoped credential files; those
   are delivered again at boot. Do not copy owner credentials into the guest.
3. Stop `microvm@robots.service`. Check the restored **copy** with `e2fsck -p`
   before installing it. Exit status 0 or 1 is acceptable; investigate other
   results. To recover individual files, mount that copy read-only after journal
   recovery instead of replacing the VM disk.
4. Move the original `root.img` aside. Copy the restored image using
   `cp --sparse=always` to a temporary file in `/var/lib/microvms/robots`, set its
   owner/group to those of the original disk and mode `0600`, then rename it to
   `root.img`. Never overwrite a disk still opened by QEMU.
5. Start `microvm@robots.service`, run `robots-health`, and check saved work,
   Nix-store paths, SSH identity, Rex, and application access. The restored disk
   carries its old Tailscale and agent login state; revoke/re-enroll those logins
   deliberately if recovery follows a suspected credential compromise.

`checks.x86_64-linux.robots-backup` uses a disposable ZFS pool and encrypted local
Restic repository to back up a mounted ext4 image, change the live disk, restore
with sparse allocation, recover the filesystem, and verify the earlier file.
It also checks that the VM service is not restarted, missing disks fail closed,
owned stale snapshots are recovered, unrelated snapshots survive, and failed
Restic preparation cleans up the temporary snapshot. This is a restore rehearsal
with test data; the first production off-site backup still needs verification.

References: [OpenZFS snapshots](https://openzfs.github.io/openzfs-docs/Basic%20Concepts/Datasets/Snapshots%20and%20Clones.html),
[Restic sparse restore](https://restic.readthedocs.io/en/stable/050_restore.html).
