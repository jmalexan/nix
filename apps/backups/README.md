# Backups

NASA's independent, read-only ZFS and Restic monitoring app. The host collector
reads ZFS pools/devices/scrubs, filesystem snapshots, Restic snapshot metadata,
and systemd backup state every 15 minutes. The web service only reads its
report; it has no ZFS devices, Restic credentials, command API, or restore
controls. Backup and scrub schedules handle these tasks automatically; manual
trigger controls are not planned.

The dashboard uses the shared microapp UI and private owner account service. Use
the same `owner` password as Approve and Updates at `https://backups`. Its
origin, session database, and service credentials remain independent; the web
service alone is an authorized account socket client. Reports require sign-in;
only the shell, auth endpoints, schema, and minimal health endpoint are public
within the LAN/Tailscale restriction. Reports are never static assets.

## Health and notifications

Warnings cover 80% pool utilization, overdue snapshots for opted-in datasets,
and no completed scrub in 40 days. Snapshot expectations mirror NixOS's zfstools
service: unset properties do not opt a dataset in; interval-specific properties
override the general property, and unmounted datasets are skipped. Only schedules
enabled in Nix with nonzero retention are monitored. The shortest enabled cadence
sets freshness: frequent one hour, hourly two hours, daily two days, weekly nine
days, monthly forty days. Unconfigured root datasets are shown as **Not configured**
instead of raising an overdue warning; actual pool/device errors still alert. Errors cover 90% utilization,
unhealthy pools/devices, nonzero disk counters, data/scrub errors, failed
backup/database units, missing successful backup completion or remote snapshot
within 36 hours, and reports older than 30 minutes. Probe failures are visible
and never replaced with fabricated healthy values. Missing reports remain
unknown and alert.

Restic start/stop hooks record service results and a bounded 30-run history.
Exit 3 is a failure and cannot advance the last-success timestamp. The result
includes pruning; a pruning failure can conservatively mark an otherwise
completed upload as a failed attempt. History begins on the next backup after
deployment; existing remote snapshots are displayed without claiming their runs
succeeded. Collection reads remote snapshots without acquiring a repository lock
and never invokes backup, prune, check, restore, or snapshot creation/deletion.

A separate notifier checks report health every five minutes, including collector
staleness, and publishes to the existing notification bridge with a dedicated
`backups` credential scoped to the short and full origins and the owner.
Notification links use `https://backups/`. Problem notifications send on changes
and repeat daily while unresolved. Routine healthy days are silent. A single
**Backups recovered** notification requires a new successful backup after the
last reported issue, with all monitored alerts cleared and no backup still running.
Clearing a storage warning or stale-report alert alone does not send success.
The notifier tracks problem evidence even while duplicate alerts are suppressed;
collector lag does not force waiting an extra day after a successful backup.
Transient network/gateway failures retry on the next timer without failing
activation. Notification actions are empty. The owner confirmed receipt of status
notifications on 2026-11-11; delivery uses the existing bridge enrollment/APNs setup.

Coverage lists evaluated Restic paths, exclusions, and retention directly from
Nix. Dataset inclusion is based on mountpoint containment and is explicitly
subject to exclusions; datasets entirely under an excluded directory are marked
as excluded. A running scrub preserves its previously observed completion time.
The robots VM disk is listed separately as a raw ZFS snapshot path; the root
dataset is not presented as completely protected. Snapshot sizes are logical
bytes processed, not B2 storage usage or billing. Durations are computed from Restic snapshot summary `backup_start` and
`backup_end`, including retained snapshots created before this dashboard. Metadata
absent from an older snapshot is labelled **Not stored in snapshot** rather than
invented. The **Recovery checks** section explains operator checks; the app does
not run or track repository checks or restore tests. Successful snapshots do not
prove recovery was tested.

## Checking recovery

On a trusted NASA administrator terminal, the existing Nix-generated Restic
wrapper loads the configured repository credentials without copying them:

```sh
sudo restic-backblaze check
sudo restic-backblaze snapshots
```

The first command checks repository structure/metadata. It does not read all file
data; Restic's data-reading check options can test stored data, but may involve
substantial Backblaze downloads and retrieval charges. Schedule checks separately
from backup/prune jobs. For an actual restore test, choose a small important file
and its snapshot, replace the placeholders, and restore into a separate directory:

```sh
sudo restic-backblaze restore SNAPSHOT_ID --target /var/tmp/backups-restore-test --include /Data/smb/path/to/a-small-file
```

Open the restored file and compare it against its expected backed-up version.
For database dumps, import into a disposable database, never the running service.
These are operator tasks; this change does not run them, add restore controls, or
claim their results. Running a check does not change the dashboard's status.

## Deployment and recovery

The NASA module exposes `https://backups` and its full hostname through nginx's
private access policy, proxying to loopback 8101. Both URLs support direct
shared account password sign-in with independent remembered sessions. The short
URL is preferred for people and notification links. No separate Backups setup
code or passkey enrollment is required. If the shared account is not yet
configured, use **Set up account** and the existing shared account setup process
in [app accounts](../../docs/app-accounts.md). The web service requires its
account socket configuration and fails closed if that service is unavailable.

The service restarts after new unit definitions are installed, following the
shared app activation convention. `nasa-apps-health` includes Backups' short
HTTPS route and authentication API. Existing backup schedules and retention are
unchanged. No NASA connection is needed to prepare this app; production follows
the repository PR release process. Check password autofill on the actual device.

The auth database is `/var/lib/backups-auth/state.sqlite`; a consistent SQLite
copy is added to the database-backup dependency chain under
`/Data/smb/Internal/Backups/microapps/backups-auth.sqlite`. The notification
publisher credential joins the encrypted offsite backup paths; shared account
credentials and database backups stay with the account service. Reports/history
are derived monitoring state and are not restore evidence. After restoring
session state, clear its sessions before serving requests again. Account
recovery/reset follows the shared account procedure and invalidates sessions
across all apps; do not reset the shared account to clear only Backups sessions.
Signing out of Backups does not sign out other apps or hostnames.

## Development

From the repository in `nix develop .#microapps`:

```sh
export PYTHONPATH="$PWD/apps/backups:$PWD/apps/microapps/backend:$PWD/hosts/nasa/services/updates-dashboard"
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
