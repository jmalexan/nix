# Independent micro apps

The first executable slice is an approval PWA with password sign-in, remembered sessions, a request-only API, atomic single-use decisions, a harmless verification
worker, and a Web Push outbox. An optional, separately deployed
[connection gate](../../docs/approval-ssh-gate.md) adds phone-approved SSH to a
dedicated account without sudo. It is enabled and verified on NASA.
Approvals and System updates share theme tokens, headers, buttons, status
indicators, and empty states. Keep copy brief: omit subtitles and explanations
when the interface already communicates the purpose. See the
[design follow-ups](../../docs/microapp-design-followups.md).

## Development

After new files are included in your checkout's Git index, run from the repository:

```sh
nix develop .#microapps
export PYTHONPATH="$PWD/apps/microapps/backend"
python apps/microapps/export_api.py
cd apps/microapps/web
npm ci
npm run api:types
npm run build
python ../backend/tests/serve.py
```

Visit `http://localhost:5173`. This **disposable local test server** uses known test
credentials (`e` repeated 32 times for enrollment, `r` repeated 32 times for the
requester, `w` repeated 32 times for the worker). It deletes its database on exit.
Choose **Set up account**, enter the test setup code, and create a password of
at least 15 characters. This signs in immediately. The username is `owner`. It is bound to loopback and is not a phone-accessible deployment.

Submit a harmless request from another local terminal:

```sh
curl --fail http://localhost:5173/api/requests \
  -H 'Authorization: Bearer rrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrr' \
  -H 'Content-Type: application/json' \
  -d '{"operation":"demo.verify","reason":"Check the approval flow"}'
```

Approve or deny it in the browser. After approval, POST to
`/api/worker/<request-id>/verify` using the worker test credential. The first
successful execution records completion; any subsequent execution is rejected.
Requests expire after ten minutes. Approved grants must be used within two minutes
and never outlive the original request deadline.

For frontend iteration, run the backend on port 8092 with the same configured
origin (`http://localhost:5173`) and `npm run dev` on 5173. The Vite proxy preserves
that Host header. The packaged application uses a single origin for API and UI.

## Verification

```sh
PYTHONPATH=apps/microapps/backend pytest -q apps/microapps/backend/tests
nix build .#approvals .#checks.x86_64-linux.microapps
cd apps/microapps/web
npm run build
# Use a Chromium executable available on your machine:
CHROMIUM_PATH=/path/to/chromium npm run test:browser
```

The browser tests start disposable backends, including an HTTPS server for short
hostnames. They exercise shared account setup, direct sign-in to both tools, and
remembered sessions, CSRF-protected decisions, one-time execution, and compact to
expanded resizing. It does not prove iPhone push delivery or Duo hardware behavior.

`openapi.json` and `web/src/api.d.ts` are generated artifacts. Regenerate both when
changing API models. CI checks backend/schema consistency and compiles the frontend.
Browser tests run separately with Chromium. Keep package-lock.json and
`npmDepsHash` in default.nix synchronized when dependencies change.

See [Updates authentication](../../docs/updates-auth.md) for the second consumer
of the shared account/session implementation.

## Reuse and ownership

- `backend/microapps/runtime.py`: common HTTP origin/size/security defaults.
- `backend/microapps/store.py`: transactional approval/auth/outbox storage.
- `backend/microapps/api.py`: the approval app.
- `backend/microapps/accounts.py`: private owner account, verification client, and recovery generation.
- `backend/microapps/auth.py`: per-app/hostname sessions and CSRF checks.
- `backend/microapps/notify.py`: reusable serialized outbox delivery pattern.
- `web/src/shared/`: tokens, framework-neutral Web Components, native control
  styles, and thin React wrappers. System updates packages the same JS and CSS.
- `modules/microapps.nix`: per-app identity, credentials, state, and sandboxing.

New apps get separate service declarations, origins, and databases. Start with
`create_service(title, origin)` and explicit Pydantic models for the API. Only
apps requiring approvals should adopt the approval tables and routes. Use the shared owner account service for human sign-in, following
[Shared app account](../../docs/app-accounts.md). Keep application databases,
sessions, and machine credentials independent.

## Host deployment

The prototype was deployed to NASA on 2026-11-05. The host inventory enables
`hosts/nasa/services/approvals.nix` with its public VAPID key.
`services.approvals.enable = true` enables the demo service on localhost:8092 and
`https://approve` (also `https://approve.nasa.jmalexan.com`) through the existing private nginx listener.
It uses its own DynamicUser and state directory. The inventory also enables
`services.approvals.sshGate.enable`, deployed and verified on 2026-11-06. This adds
the dedicated gate account/listener and denies that account through ordinary SSH.
Owner SSH and Rex authorization remain separate. Releases use the repository PR
workflow; host inspection uses the separately approved NASA connection flow.

Before activation, a trusted host operator provisions two independently random,
at-least-32-character credentials in root-only files under
`/var/lib/microapp-secrets/approvals/{requester,worker}`. The directory
must be mode 0700 and files mode 0600. systemd LoadCredential makes them available
to the app without embedding them in the Nix store. Give only the requester
credential to automation. Keep the worker credential separate. Shared account
setup has its own operator-only code; see
[Shared app account](../../docs/app-accounts.md). Never use local test credentials
for a host deployment.

With the owner's explicit permission, the development container stores only the
requester credential at `.local/approvals/requester` in this repository (directory
0700, file 0600, excluded from Git). API clients should read it directly and send
it as a Bearer authorization header, without printing it or placing it in command
arguments. This permits creating demo and SSH requests without an SSH connection;
it cannot approve requests or claim grants. Worker, gate, and account setup
credentials remain on the host. The gate uses a fourth distinct credential at
`/var/lib/microapp-secrets/approvals/gate` with the same root-only protections.

NASA enables one shared owner account for Approve and Updates. Create it once in
either app, then use the same password in both. Initial setup is protected by the
shared operator code; it closes after the account is created. Existing app-local
passwords, passkeys, and sessions are ignored when the shared service is enabled.
App data and notification pairing stay intact. There is no password-changing UI
or sign-in hand-off. New passwords need at least 15 characters, and forms support
Bitwarden autofill. See [Shared app account](../../docs/app-accounts.md) for setup,
isolation, hashing, throttling, and account recreation.

Human-facing links, including notifications, prefer short HTTPS names; machine
APIs retain their configured full addresses. Session cookies are HttpOnly, Secure,
SameSite=Strict, host-only, and expire after 30 days. Signing out revokes that
session. Account recreation invalidates all app sessions.

For push, provision a VAPID private PEM key at
`/var/lib/microapp-secrets/approvals/vapid.pem`, with the same file protections.
Set `services.approvals.vapidPublicKey` to the corresponding URL-safe base64
uncompressed P-256 public key. This enables the serialized notification timer.
The main-screen **Enable notifications** helper registers this browser's subscription
and disappears once setup succeeds. Existing subscriptions are reconciled with
server storage when the app opens; permission alone does not count as setup.
On iPhone, first install the app on the Home Screen. The NAS requires outbound
HTTPS to the push provider. Opening a request still needs LAN or Tailscale access.

Push delivery is at least once across crashes: notification tags coalesce repeated
requests, while the backend always rechecks state/expiry. A notification never
approves anything. Expired/denied/completed requests are dropped from delivery.
Only known browser push-provider HTTPS endpoints can be registered. Failed
subscriptions are removed on 404/410. On 2026-11-06 the owner confirmed physical
iPhone notification delivery and opening the correct request. The resulting
approval completed `demo.verify` successfully, and a repeated execution returned
409 (`No unused approval available`). Duo hardware testing is deferred.

## Recovery and backups

When enabled, the host module adds a consistent SQLite snapshot under
`/Data/smb/Internal/Backups/microapps/approvals.sqlite` to the existing database
backup dependency chain before Restic runs. Backup fails if `/Data/smb` is not
mounted. For an additional manual snapshot, use
`python -m microapps.admin backup --database /var/lib/microapp-approvals/state.sqlite
--output <new-backup-path>`. The command refuses
to overwrite an existing path. Live database files are not a consistent backup.
Back up the credential files separately through the existing encrypted secret
workflow. Do not make these files readable by the development container.

For lost-password recovery, use the local shared-account reset procedure in
[Shared app account](../../docs/app-accounts.md). It invalidates sessions without
deleting requests, reports, or notification pairing. Restoring the shared account
database requires that reset before allowing sign-in. The older approval-specific
`microapps.admin reset-auth` operation also invalidates pending/approved grants and
subscriptions when recovering approval state after a data restore; it is not the
shared password recovery operation. There is no remote recovery endpoint.

## Remaining stages

The foundation, mobile proof, and live connection gate are verified. Broader
dashboard service adoption and restrictions on alternate access paths remain
outstanding. The gate must not be presented as enforcement across unrelated
host-access paths such as owner SSH, Rex, and production deployment.
