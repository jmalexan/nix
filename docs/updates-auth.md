# Updates authentication

Updates uses the same passkey authentication backend, browser ceremony helpers,
sign-in styling, and HTTP security defaults as Approve. Each app retains its own
origin, passkey registration, setup credential, SQLite database, and host-only
session cookie. Signing in to one app grants no access to the other. No global
navigation or cross-origin authentication service is introduced.

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

Open `https://updates.nasa.jmalexan.com`, choose **Set up this app**, enter the
code, and create a passkey. Keep the code in the trusted terminal and app; do not
send it through agent logs or chat. Enrollment closes after the first successful
registration. Then choose **Sign in with passkey**. Use the canonical hostname;
short hostname aliases are not accepted as alternate authentication origins.

Sessions last 30 days, persist across service restarts, and require a verified
passkey ceremony with user verification. Cookies are HttpOnly, Secure,
SameSite=Strict, and host-only. Signing out revokes the server session immediately.
Expired sessions return the dashboard to its sign-in screen.

## Backup and recovery

The auth database is `/var/lib/updates-dashboard-auth/state.sqlite`, separate
from reporter files. A consistent SQLite snapshot is written to
`/Data/smb/Internal/Backups/microapps/updates-auth.sqlite` in the existing database
backup chain. The setup code joins the encrypted Restic backup paths.

After restoring an auth database, clear its restored sessions and challenges
before restarting the app so revoked sessions are not resurrected. Reset also
removes the registered passkey, so enroll again. For lost passkeys or recovery,
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
queued scans, and PR jobs are preserved. Use the new setup code to enroll again.

## Validation

Backend checks cover signed-out report and legacy-route access, CSRF and Origin,
session expiry/logout, independent credentials, constrained action models, and
private setup provisioning. Browser tests use real WebAuthn ceremonies with a
virtual authenticator to cover enrollment, login, remembered sessions, scan
submission, mobile layout, and sign-out. They do not replace a physical-device
passkey check after deployment.
