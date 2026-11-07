# Updates authentication

Updates and Approve use the [shared owner account](app-accounts.md). Create it
once in either app, then use username `owner` and the same password at
`https://updates`, `https://approve`, or either app's full hostname. Each app and
hostname keeps its own session. Notifications retains device pairing.

Initial setup, the one-time migration from app-local passwords/passkeys, private
account storage, rate limits, account recreation, and backup recovery are described
in [Shared app account](app-accounts.md). There is no password-changing or account
management screen. Short URLs require the DHCP search domain and private CA trust.

The Updates HTTP server is FastAPI. Report collectors, scan triggers, and PR workers
retain their independent queues and permissions. Report contents and queue status
require a human session. Scan and PR actions also require a session CSRF token and
the matching Origin. Legacy `/pipeline/reports` links require authentication before
redirecting to the dashboard. Report JSON files are not public assets. Only the app
shell, static assets, authentication routes, schema, and minimal health endpoint
are public within the existing LAN/Tailscale restriction.

Updates stores its sessions in `/var/lib/updates-dashboard-auth/state.sqlite`,
separate from reporter files and the shared account database. The existing backup
chain snapshots that database at
`/Data/smb/Internal/Backups/microapps/updates-auth.sqlite`. Resetting the shared
account invalidates restored sessions without deleting report or queue data.

The API contract is `hosts/nasa/services/updates-dashboard/openapi.json`, with
generated TypeScript declarations alongside it. Packaged checks verify both.
Backend and browser checks cover protected reports/actions, password sign-in,
separate sessions, CSRF/Origin, constrained action models, and remembered login.
