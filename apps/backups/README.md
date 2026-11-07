# Backups

NASA's independent, read-only ZFS and Restic monitoring app. The host collector
reads ZFS pools/devices/scrubs, filesystem snapshots, Restic snapshot metadata,
and systemd backup state every 15 minutes. The web service only reads its report;
it has no ZFS devices, Restic credentials, command API, or restore controls.

The dashboard uses the shared microapp UI and passkey implementation, with its
own origin, enrollment credential, auth database, and sessions. Reports require
sign-in; only the shell, auth ceremonies, schema, and minimal health endpoint
are public within the LAN/Tailscale restriction. Reports are never static assets.

## Health and notifications

Warnings cover 80% pool utilization, missing/overdue frequent snapshots (one
hour), and no completed scrub in 40 days. Errors cover 90% utilization, unhealthy
pools/devices, nonzero disk counters, data/scrub errors, failed backup/database
units, missing successful backup completion or remote snapshot within 36 hours,
and reports older than 30 minutes. Probe failures are visible and never replaced
with fabricated healthy values. Missing reports remain unknown and alert.

Restic start/stop hooks record service results and a bounded 30-run history.
Exit 3 is a failure and cannot advance the last-success timestamp. The result
includes pruning; a pruning failure can conservatively mark an otherwise
completed upload as a failed attempt. History begins on the next backup after
deployment; existing remote snapshots are displayed without claiming their runs
succeeded. Collection reads remote snapshots without acquiring a repository lock
and never invokes backup, prune, check, restore, or snapshot creation/deletion.

A separate notifier checks report health every five minutes, including collector
staleness, and publishes to the existing notification bridge with a dedicated
`backups` credential scoped to this origin and the owner. It sends on changes,
repeats unresolved alerts daily, retries failures on the next timer, and reports
recovery. Notification actions are empty. iPhone delivery still depends on the
existing bridge device enrollment/APNs configuration.

Coverage lists evaluated Restic paths, exclusions, and retention directly from
Nix. Dataset inclusion is based on mountpoint containment and is explicitly
subject to exclusions; datasets entirely under an excluded directory are marked
as excluded. A running scrub preserves its previously observed completion time. The robots VM disk is listed separately as a raw ZFS
snapshot path; the root dataset is not presented as completely protected.
Snapshot sizes are logical bytes processed, not B2 storage usage or billing.
The app does not run repository verification or restore tests; both show
**not recorded**. Successful snapshots do not prove recovery was tested.

## Deployment and recovery

The PR targets NASA only, adding `https://backups.nasa.jmalexan.com` on loopback
8093 behind the existing certificate and private nginx access policy. Existing
backup schedules and retention are unchanged. No SSH connection is needed to
prepare this app; production follows the repository PR release process.

Activation provisions a private setup code at
`/var/lib/microapp-secrets/backups/enrollment`. On a trusted NASA terminal, read
it with `sudo cat /var/lib/microapp-secrets/backups/enrollment`, open the canonical
URL, select **Set up this app**, create a passkey, then sign in. Keep the code
out of chat/logs. Physical iPhone enrollment and notification delivery require
post-deployment verification.

The auth database is `/var/lib/backups-auth/state.sqlite`; a consistent SQLite
copy is added to the database-backup dependency chain under
`/Data/smb/Internal/Backups/microapps/backups-auth.sqlite`. Setup and notification
credentials join the encrypted offsite backup paths. Reports/history are derived
monitoring state and are not restore evidence. After restoring auth state, stop
`backups-web` and `backups-notify`, rotate the setup code, and use
`microapp-auth-admin reset --database /var/lib/backups-auth/state.sqlite
--confirm-reset` before re-enrollment to revoke restored sessions/challenges.
Other apps' passkeys/sessions remain separate.

## Development

From the repository in `nix develop .#microapps`:

```sh
export PYTHONPATH="$PWD/apps/backups:$PWD/apps/microapps/backend"
pytest -q apps/backups/tests
python apps/backups/export_api.py > apps/backups/openapi.json
cd apps/microapps/web
npm ci
npx --no-install openapi-typescript ../../backups/openapi.json -o ../../backups/web/api.d.ts
npx --no-install prettier --write ../../backups/web/api.d.ts
```

`nix build .#checks.x86_64-linux.backups` checks tests and schema consistency.
The shared frontend package verifies generated TypeScript. Reports and API use
Pydantic models; regenerate both contract artifacts after model changes.
