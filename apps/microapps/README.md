# Independent micro apps

The first executable slice is an approval PWA with passkey sign-in, remembered
sessions, a request-only API, atomic single-use decisions, a harmless verification
worker, and a Web Push outbox. An optional, separately deployed
[connection gate](../../docs/approval-ssh-gate.md) adds phone-approved SSH to a
dedicated account without sudo. It is enabled and verified on NASA.
The approval UI is the first consumer; System updates adopts shared theme tokens.

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
Choose **Set up this app**, enroll a passkey using the test setup code, then sign
in. It is bound to loopback and is not a phone-accessible deployment.

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

The browser test starts its own disposable backend. It uses Chromium's virtual
WebAuthn authenticator to exercise real registration and verification, then tests
remembered login, CSRF-protected decisions, one-time execution, and compact to
expanded resizing. It does not prove iPhone push delivery or Duo hardware behavior.

`openapi.json` and `web/src/api.d.ts` are generated artifacts. Regenerate both when
changing API models. CI checks backend/schema consistency and compiles the frontend.
Browser tests run separately with Chromium. Keep package-lock.json and
`npmDepsHash` in default.nix synchronized when dependencies change.

## Reuse and ownership

- `backend/microapps/runtime.py`: common HTTP origin/size/security defaults.
- `backend/microapps/store.py`: transactional approval/auth/outbox storage.
- `backend/microapps/api.py`: the approval app and initial passkey integration.
- `backend/microapps/notify.py`: reusable serialized outbox delivery pattern.
- `web/src/shared/tokens.css`: common presentation tokens, also used by updates.
- `modules/microapps.nix`: per-app identity, credentials, state, and sandboxing.

New apps get separate service declarations, origins, and databases. Start with
`create_service(title, origin)` and explicit Pydantic models for the API. Only
apps requiring approvals should adopt the approval tables and routes. The first
passkey integration remains in the approval app pending a second real consumer;
shared authentication should be extracted along that real boundary.

## Host deployment

The prototype was deployed to NASA on 2026-11-05. The host inventory enables
`hosts/nasa/services/approvals.nix` with its public VAPID key.
`services.approvals.enable = true` enables the demo service on localhost:8092 and
`https://approve.nasa.jmalexan.com` through the existing private nginx listener.
It uses its own DynamicUser and state directory. The inventory also enables
`services.approvals.sshGate.enable`, deployed and verified on 2026-11-06. This adds
the dedicated gate account/listener and denies that account through ordinary SSH.
Owner SSH and Rex authorization remain separate. Deployment requires explicit
NASA connection permission.

Before activation, a trusted host operator provisions three independently random,
at-least-32-character credentials in root-only files under
`/var/lib/microapp-secrets/approvals/{requester,worker,enrollment}`. The directory
must be mode 0700 and files mode 0600. systemd LoadCredential makes them available
to the app without embedding them in the Nix store. Give only the requester
credential to automation. Keep the worker credential separate, and deliver the
enrollment credential directly to the owner on a trusted device. Never use the
local test credentials for a host deployment.

With the owner's explicit permission, the development container stores only the
requester credential at `.local/approvals/requester` in this repository (directory
0700, file 0600, excluded from Git). API clients should read it directly and send
it as a Bearer authorization header, without printing it or placing it in command
arguments. This permits creating demo and SSH requests without an SSH connection;
it cannot approve requests or claim grants. Worker, gate, and enrollment
credentials remain on the host. The gate uses a fourth distinct credential at
`/var/lib/microapp-secrets/approvals/gate` with the same root-only protections.

Enrollment is accepted only while the credential table is empty and consumes a
short-lived challenge. A second concurrent enrollment cannot replace the owner.
The first version supports one owner passkey. Login cookies are HttpOnly, Secure,
SameSite=Strict, host-only, and expire after 30 days. Signing out revokes the
server-side session. Verify HTTPS trust, DNS, and passkey use on the actual iPhone.

For push, provision a VAPID private PEM key at
`/var/lib/microapp-secrets/approvals/vapid.pem`, with the same file protections.
Set `services.approvals.vapidPublicKey` to the corresponding URL-safe base64
uncompressed P-256 public key. This enables the serialized notification timer.
The browser's **Enable notifications** action registers its own subscription.
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

If the passkey is lost, a trusted operator stops the gate socket (when enabled),
web and notification units,
rotates the enrollment credential, and runs `python -m microapps.admin reset-auth
--database <database> --confirm-reset`. This revokes sessions/challenges, removes
subscriptions, and invalidates pending/approved/claimed requests before re-enrollment.
After restoring a database backup, perform this reset before starting the app to
prevent previously consumed grants or revoked sessions from being restored.
There is deliberately no remote recovery endpoint. Keep the operation and secrets
out of automation's request-only API.

## Remaining stages

The foundation, mobile proof, and live connection gate are verified. Broader
dashboard service adoption and restrictions on alternate access paths remain
outstanding. The gate must not be presented as enforcement across unrelated
host-access paths such as owner SSH, Rex, and production deployment.
