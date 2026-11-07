# Updates authentication

Updates and Approve share password sign-in, styling, and HTTP security defaults.
Each app keeps its own password, setup credential, database, and host-only session.
The same app password works directly at its short HTTPS URL and full hostname;
sessions stay separate for each hostname. Existing passkeys remain usable at the
full hostname. No authentication hand-off or shared cross-app login is used.

The Updates HTTP server is FastAPI. The existing report collectors, scan triggers,
and PR workers retain their existing queues and permissions. Report contents and
queue status require a human session. All scan and PR actions also require a
session CSRF token and the configured Origin. The old dashboard-wide action token
is removed. Legacy `/pipeline/reports` links require authentication before
redirecting to the dashboard. Report JSON files are not served as public assets.
Only the app shell, static assets, authentication ceremonies, schema, and minimal
health endpoint are public within the existing LAN/Tailscale network restriction.

The API contract is in `hosts/nasa/services/updates-dashboard/openapi.json`, with
generated TypeScript declarations alongside it. Packaged checks verify both.
There is no HTTP owner-reset or machine-token bypass.

## First deployment

Activation generates a root-only setup code at
`/var/lib/microapp-secrets/updates/enrollment`. Existing codes are preserved; an
unsafe existing file fails provisioning rather than being replaced. The web
service loads it through systemd credentials. It is never embedded in the Nix
store, a GitHub secret, or a URL.

On a trusted NASA terminal, run:

```sh
sudo cat /var/lib/microapp-secrets/updates/enrollment
```

Open `https://updates`, choose **Set up this app**, enter the setup code, and
create a password of at least 15 characters. The fixed username is `owner`;
standard autocomplete fields let Bitwarden save and fill it. The fully qualified
`https://updates.nasa.jmalexan.com` remains available with the same password.
Each app needs its own setup. Short names require the DHCP search domain and the
existing private CA trust.

For an already enrolled passkey owner, sign in at the full hostname and choose
**Set password**. An existing session can also set it directly. This preserves
passkeys and creates a password usable at either hostname. Unauthenticated setup
stays closed after either password or passkey enrollment. A local auth reset can
instead clear both methods for fresh password setup; no host connection is needed
to deploy this change.

Passwords use salted scrypt (N=131072, r=8, p=1); plaintext is never stored.
Login is limited per app to 10 attempts/minute and 100/hour across both hostnames,
with SQLite state surviving restarts. Sessions last 30 days; cookies are HttpOnly,
Secure, SameSite=Strict, and host-only. Changing a password revokes all previous
sessions and unfinished ceremonies and signs in the current browser afresh.
Signing out revokes that session immediately. Writes require a matching Host and
Origin plus the session CSRF token.

Human-facing links prefer short HTTPS URLs, including native and Web Push approval
notifications (`https://approve/?request=...`) and companion settings
(`https://notifications`). Machine APIs retain their configured full addresses.

## Backup and recovery

The auth database is `/var/lib/updates-dashboard-auth/state.sqlite`, separate
from reporter files. A consistent SQLite snapshot is written to
`/Data/smb/Internal/Backups/microapps/updates-auth.sqlite` in the existing database
backup chain. The setup code joins the encrypted Restic backup paths.

After restoring an auth database, clear its restored sessions and challenges
before restarting the app so revoked sessions are not resurrected. Reset also
removes the password and registered passkey, so set up again. For lost credentials or recovery,
use a trusted administrator terminal; stop Updates, rotate its setup credential,
clear auth state, then restart:

```sh
sudo systemctl stop updates-dashboard.service
sudo rm /var/lib/microapp-secrets/updates/enrollment
sudo systemctl restart updates-dashboard-auth-credentials.service
sudo microapp-auth-admin reset \
  --database /var/lib/updates-dashboard-auth/state.sqlite --confirm-reset
sudo systemctl start updates-dashboard.service
```

This does not affect Approve credentials or sessions. Existing reporter state,
queued scans, and PR jobs are preserved. Use the new setup code to create a password again.

## Validation

Backend checks cover password enrollment/login, throttling, password changes and
session revocation across hostnames, plus signed-out report and legacy-route
access, CSRF and Origin, session expiry/logout, independent credentials,
constrained action models, and private setup provisioning. Browser tests cover
password setup and login at short HTTPS and full hostnames, remembered sessions,
password changes, scan submission, mobile layout, and sign-out. Verify Bitwarden
save/autofill and DHCP search-domain resolution on your actual clients after
deployment.
