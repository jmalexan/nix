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
