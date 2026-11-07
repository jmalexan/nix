# Shared app account

Approve (`https://approve`) and Updates (`https://updates`) use one owner account,
with username `owner` and the same password at both tools and their full hostnames.
Sign in directly on the page you opened. Each app and hostname keeps a separate
remembered session; signing out of one does not sign out the other. Notifications
continues to use its existing device pairing and companion settings tickets.

There is no password-changing screen, account editor, or HTTP recovery endpoint.
If recovery is needed, a host operator resets the account and creates it again.

## Initial setup and migration

The first deployment creates a fresh shared account store. Existing app-local
passwords, passkeys, and browser sessions are no longer used by Approve or Updates.
Their application data, requests, report state, and notification/device enrollment
are preserved. Do not delete their application databases to reset the account.

NASA provisions a private setup code at
`/var/lib/microapp-secrets/accounts/enrollment`. The account service alone loads it
through systemd credentials. From a trusted NASA administrator terminal:

```sh
sudo cat /var/lib/microapp-secrets/accounts/enrollment
```

Open either tool, choose **Set up account**, enter that code, and choose a password
of at least 15 characters. Choose **Create account** to finish. The account is now
available for password sign-in in both tools; setup closes everywhere atomically.
The forms have standard username/password autocomplete fields for Bitwarden.
The setup code must stay out of chat, logs, URLs, and the Nix store.

## Isolation and sessions

`microapp-accounts.service` owns `/var/lib/microapp-accounts/state.sqlite` and
listens only on `/run/microapp-accounts.sock`. Only explicitly configured client
services get the socket's group. Client apps can verify passwords and forward the
owner's initial setup code, but cannot read password hashes, change a password,
reset the account, or access another app's data or sessions through this service.
There is no nginx route or network listener for accounts.

Passwords use salted scrypt (N=131072, r=8, p=1). Login limits of 10 attempts/minute
and 100/hour apply across both tools and all their hostnames, and survive restarts.
A failed or unavailable account service never falls back to old app credentials.

Sessions are HttpOnly, Secure, SameSite=Strict, host-only, and last 30 days. Writes
require the matching Host/Origin and a session CSRF token. Session identifiers are
bound to the account generation and hostname. Resetting the account invalidates
all existing sessions across both apps, including after a replacement account is
created. The apps retain independent service identities and session databases.

For another app, configure its `systemd` service in
`services.microappAccounts.clients` and pass `MICROAPP_ACCOUNT_SOCKET` into its
shared-auth settings as `account_socket`. Keep its origin, application database,
and service credentials separate. The shared account grants owner access to each
configured app; it does not create a general user/role management system.

## Recovery and backups

On NASA, stop the socket and service, reset the account, rotate the setup code,
and reopen the socket. This does not delete app data or notification pairing:

```sh
sudo systemctl stop microapp-accounts.socket microapp-accounts.service
sudo microapp-auth-admin reset \
  --database /var/lib/microapp-accounts/state.sqlite --confirm-reset
sudo rm /var/lib/microapp-secrets/accounts/enrollment
sudo systemctl restart microapp-account-credentials.service
sudo systemctl start microapp-accounts.socket
```

Use the new setup code to create the replacement account in either app. The reset
changes the account generation, so old sessions cannot become valid again.
Account-service restarts preserve the current account and generation.

The existing database backup chain takes a consistent SQLite snapshot at
`/Data/smb/Internal/Backups/microapps/accounts.sqlite` before Restic. The setup code
is also included in the encrypted backup. Each app's own database backup remains
separate. After restoring an account backup, perform the account reset above before
allowing sign-in so a restored generation cannot resurrect old browser sessions.

## Verification

Backend tests exercise two independent apps against the real Unix-socket account
API: single setup, common credentials, separate sessions, cross-app throttling,
local reset/recreation, rejection of old app-local credentials, and account-service
failure. Chromium tests create the account once and sign in directly to both short
and full HTTPS hostnames. The NixOS VM check runs the socket-activated production
service and verifies group access, private database permissions, readiness, and
app restart behavior. Verify Bitwarden save/autofill on the actual client.
