# Phone-approved NASA connections

Status: deployed and verified on NASA on 2026-11-06 after explicit owner
authorization. The owner approved a live request from the phone; the connection
ran as `nasa-automation`, verified read-only access and blocked sudo, and closed
successfully without using a forwarded agent. Reusing the consumed request was
rejected before SSH negotiation. No gate session processes remained afterward.
Packaged checks and real SSH/systemd VM lifetime/crash tests also passed.

The activated isolated configuration is
`/nix/store/hqip1zc4k4rv5mrxv0bgk328640m339i-nixos-system-nasa-26.05.20261102.7dcdd87`.
Comparison with the previously deployed closure shows new gate units and changes
to the approval web/notification units, ordinary sshd's configuration trigger,
and the manual-page index. The container and existing application service units
are unchanged. Activation reloaded D-Bus and restarted polkit and the SSH listener;
the development container and application stacks were not restarted. The
maintenance connection was closed after verification. A root-only pre-activation
SQLite backup is at `/var/lib/microapp-secrets/approvals/before-ssh-gate.sqlite`.

## Connection contract

An `ssh.connect` request binds a reason, NASA, the `nasa-automation` account, a
temporary Ed25519 public key, and a maximum lifetime of 900 seconds. The phone
shows the account, read-only access, and lifetime before approval. Older clients
cannot approve this operation without submitting the exact reviewed scope.

The client generates a temporary private key locally, submits its public half
using the existing request-only credential, and waits for a human decision.
Pending requests expire in ten minutes; approval must be claimed within two
minutes and before the original deadline. No forwarded agent or new Tailscale
identity-provider login is needed by this workflow.

After approval, the client sends the request ID to the private gate on
`10.0.1.10:2222`, then performs ordinary SSH through that same socket. The ID is
only a selector; possession of the matching private key is still required.
The client verifies NASA's existing host key and disables agent use, forwarding,
and connection multiplexing. It makes no automatic reconnection attempts.

The gate uses its own credential to atomically consume the approved grant. It
independently validates the fixed account, target, lifetime, and public key before
starting `sshd -i` for that one accepted TCP socket. An invalid key or interrupted
handshake consumes the grant. Every reconnect needs another approval. A caller
who learns a request ID could cause a denial of service by consuming it, but
cannot authenticate without the bound private key. The listener accepts LAN
source addresses only, and permits one connection at a time.

## Host enforcement

Each accepted socket gets a separate systemd service with `RuntimeMaxSec=900`,
`KillMode=control-group`, and `KillSignal=SIGKILL`. Its monotonic lifetime starts
before authentication. Normal disconnect, worker failure, socket-service stop,
and expiry terminate the remaining process tree, including detached processes.
No PAM/logind session is created, preventing migration into a separate user
scope. The stop hook reports the result only after process cleanup; an API outage
does not prolong the session. A lost report leaves a consumed grant that expires,
never an approval that can be reused.

The dedicated account has no sudo or additional groups. The service mounts host
files read-only and supplies private temporary space. It blocks privilege gains,
control-group changes, namespace creation, and host management sockets (system
D-Bus, systemd, Docker, user managers, and the Nix daemon). The account cannot
write a persistent home or install an authorized key. The regular host SSH
listener explicitly denies this account; the gate accepts only its one temporary
public key. It has no password, user-certificate CA, forwarding, PTY, or user RC
authentication path. Existing owner and deployment accounts are separate.

This is a shell with the account's read permissions, including network access
during its lifetime. It is not an allowlist of individual commands. Privileged
operations require a separately scoped worker or an explicitly authorized owner
connection. The gate's root supervisor and approval backend are trusted services;
the request credential alone cannot claim grants, decide requests, or enroll an
owner. Neither the gate credential nor a NAS private login key belongs in the
development container.

## Alternate-access review

The following repository findings remain relevant even after this gate is
enabled. They were inspected locally; no new NASA connection was opened for this
review.

| Route | Finding | Consequence |
| --- | --- | --- |
| Owner SSH | `modules/common.nix` installs owner keys; `modules/linux-server.nix` grants wheel passwordless sudo. Forwarded agents can authenticate through the existing wrapper. | Stop forwarding an owner agent when using the new gate. It does not revoke already available owner access. |
| Rex host login | `modules/rex.nix` grants the owner's Tailscale identity a shell as the personal account on NASA and the container. | Tailnet identity and policy must be reviewed before claiming the container has no alternate shell route. A gate listener cannot enforce policy on Rex. |
| Production deployment | `modules/ssh-deploy.nix` grants the CI identity wheel; `.github/workflows/check.yml` can activate repository revisions. | Repository/deployment permission is an administrative control path. The new gate must not be represented as constraining authorized deployments. |
| Host/container boundaries | The container joins trusted LAN bridge `br0`; copied host journals are read-only. | LAN reachability is not an approval boundary. A simple source-IP rule is insufficient if a privileged container can change its address or use its Tailscale route. |
| App APIs | Existing application identities retain their app-specific operations. | Prefer those APIs; this gate does not redefine their permissions. |

The verified claim for this change is **connections through this new entry point
require a fresh approval and have a host-enforced lifetime**. A stronger claim
that all possible container-to-host administration requires approval needs a
separate review of Rex/Tailscale identity, owner-agent availability, and production
deployment access. Preserve normal owner access from trusted devices when making
those changes.

## Deployment and use

Prepare a fourth independently random, at-least-32-character token at
`/var/lib/microapp-secrets/approvals/gate` (root-owned, mode 0600, parent 0700).
The three existing requester/worker/enrollment credentials remain distinct. The
API and root gate load the new credential; it is never given to the requester.
Provision it through an explicitly authorized maintenance connection.

The NASA inventory sets `services.approvals.sshGate.enable = true`. For a new
deployment, review and authorize activation of the isolated configuration. This creates
the dedicated account, adds its denial to the ordinary SSH listener, and starts
the separate socket. It does not remove the owner's SSH keys or change Rex.

From the repository:

```sh
python3 tools/nasa-access.py --approved \
  --reason 'Inspect host filesystem permissions that the application API does not expose' \
  -- stat /Data/smb
```

The wrapper reads `.local/approvals/requester`, requests approval, prints the
phone deep link, and waits. This mode uses only Python's standard library and the
local OpenSSH client. Alternatively, install/run the `nasa-approved-access` Nix
package. The old forwarded-agent mode remains explicit; failure in approved mode
never falls back to it. `--dry-run` sends no request and opens no connection.

Inspect logs through `nasa-journalctl -u 'approval-ssh-gate@*'`. Logs contain
request IDs, lifecycle events, and sanitized failure classes, not shell output
or credentials. Disabling the socket stops its connection units. For enrollment
reset or database restore, stop both the gate socket and approval services first;
invalidate outstanding grants before restarting. Never restore active grants as
usable authorizations.

## Verification

```sh
PYTHONPATH=apps/microapps/backend pytest -q apps/microapps/backend/tests tools/test_nasa_access.py
nix build .#checks.x86_64-linux.approval-ssh-gate
```

The integration check boots a disposable NixOS VM with real OpenSSH/systemd,
separate fixture credentials, and a shorter hard deadline. It checks no approval,
wrong keys, successful account restrictions, replay across restart, denial through
the regular SSH listener, expiry, detached process cleanup, and broker crashes.
It can run with CPU emulation when `/dev/kvm` is unavailable. API tests additionally
cover concurrent claims, scope substitution, disabled deployment, schema upgrade,
old clients, and a lost completion report. Browser tests review and approve the
connection scope at phone width using real WebAuthn with a virtual authenticator.

See [OpenSSH configuration](https://man.openbsd.org/sshd_config) and
[systemd service lifetime](https://www.freedesktop.org/software/systemd/man/latest/systemd.service.html#RuntimeMaxSec=).
