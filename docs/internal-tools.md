# Internal tools platform

Status: foundation and harmless approval prototype implemented in
[`apps/microapps`](../apps/microapps/README.md) and deployed to NASA on 2026-11-05.
Physical iPhone push delivery and request opening were confirmed by the owner on
2026-11-06. The approved demo completed once; a repeated execution returned 409.
The [SSH connection gate](approval-ssh-gate.md) was deployed and verified with a
phone-approved live connection on 2026-11-06. It uses a dedicated account without
sudo; replay was rejected and the connection left no running session processes.
The broader alternate-access restrictions remain outstanding.
The design below describes the full target.

## Purpose

Provide a reusable foundation for independent micro apps: System updates,
connection approvals, and future maintenance and inspection tools. Each app has
its own focused interface and URL. Adding an application should primarily involve
its screens, domain logic, and explicitly scoped worker, with the framework
supplying common components and infrastructure conventions.

The initial requirements are:

- Independent micro apps with shared styling and presentation conventions.
- Direct links to each app, with navigation limited to that app's own tasks.
- Mobile support as a core requirement: iPhone, an installed-app experience, and
  push notifications. Design for future iPhone Duo compatibility through compact
  and expanded layouts; access to Duo hardware is not an initial release gate.
- Remembered human sign-in, with passkey login available independently of Apple
  or Tailscale identity-provider reauthentication.
- Explicit human approval before automation establishes a NAS connection.
- Separate credentials and operating-system permissions for each worker.
- Repeatable packaging, deployment, persistence, backups, and verification in
  this Nix repository.

Approval is an application capability. Ordinary tools do not need to become
approval workflows simply because they use the platform.

A directory linking to the apps is optional. It must not become a required entry
point, a global sidebar, or a shell that every app has to embed. Sharing technical
infrastructure does not require combining the apps into one product interface.

## Existing foundation

System updates already supplies a useful model in
`hosts/nasa/services/updates-dashboard.nix`:

- Python web service, with a static browser UI.
- nginx TLS termination and a LAN/Tailscale network allowlist.
- Dedicated web and reporter users.
- Fixed trigger files and systemd path units for background jobs.
- A GitHub credential readable by the reporter, not the web process.
- Scheduled scans, normalized results, and existing regression tests.

It has no human login. Its same-origin action token prevents cross-site requests;
it does not identify an approver. The current network allowlist admits intentional
actions from any allowed client. The framework must introduce authentication
before reusing this pattern for connection approvals.

## Application and infrastructure boundaries

Build the framework as reusable packages and Nix modules, consumed by separately
deployed apps. Each app has its own process, service identity, state, credentials,
and release/restart boundary. There is no mandatory central application process
or shared application database. A common Nix deployment can still activate
multiple apps together.

Use FastAPI with Pydantic as the default backend scaffold. Keep routes small,
validate inputs and responses with explicit schemas, and publish an OpenAPI
contract. Generate TypeScript API types/clients from that contract instead of
maintaining independent copies of request and response shapes. Existing apps can
adopt deployment and styling components without a backend rewrite.

For new interactive apps, use React and TypeScript, built with Vite, with Ionic
React components for mobile interactions and platform-aware styling. Share theme
tokens and small components for typography, spacing, controls, lists, tables,
dialogs, and status/error treatments. Each app uses only the components it needs;
the framework does not impose a global tab bar or cross-app navigation.

This stack is chosen for agent-maintained development: explicit API boundaries,
type checking, runtime validation, familiar conventions, and fast test feedback.
This is an engineering judgment, not a claim that a framework makes generated
code inherently correct. Provide a complete worked example, package versions,
development commands, and contributor/agent instructions in the scaffold.

The current pinned nixpkgs includes FastAPI, Pydantic, Uvicorn, Node.js, and a
WebAuthn verification library. Pin frontend dependencies with a lockfile. The
Node toolchain builds static frontend assets; the default backend runtime is
Uvicorn. Bundle frontend assets into each app's immutable build, without a
central asset server dependency. System updates can retain its existing
JavaScript during adoption.

FastAPI does not supply a complete account/session/passkey system. The shared
authentication component needs a separately reviewed implementation using
maintained verification libraries, host-only HttpOnly cookies, session revocation,
CSRF defenses, and deliberate enrollment/recovery. Do not hand-roll WebAuthn
cryptography or treat an OpenAPI authentication declaration as an auth system.

Web processes have no general shell execution interface, general systemctl
access, NAS administrator credentials, or access to other applications' secrets.
Application backends and workers retain dedicated systemd service identities.

Conceptual layout:

```text
Human browser / installed micro app
  |
  +-- updates.<NAS domain> -- nginx -- updates web service
  |                                      |
  |                                 updates worker
  |
  +-- <app>.<NAS domain> -- nginx -- independent app service
  |                                      |
  |                                 scoped app worker (if needed)
  |
  +-- approve.<NAS domain> -- nginx -- approval service
                                            |
Automation client -- request-only API -------+
                                            |
                                      connection gate
```

Each app has a distinct browser origin and host-only cookies. The approval
service is another deployment of the reusable framework. Ordinary app JavaScript
must not be able to read or exercise an approval session. Do not share cookies
across the NAS domain or enable cross-origin approval writes. A remembered
approval-browser session is sufficient for an explicit Approve/Deny action;
passkey verification on every approval can be an optional stronger policy.

Identity and sign-in code should be reusable. Cross-origin single sign-on is a
separate integration decision: do not imitate it by broadening cookie scope.
The first version can remember each app's browser session independently.
If seamless SSO across all applications becomes necessary, use a maintained
identity-provider integration.

## What the framework supplies

| Capability | Common contract |
| --- | --- |
| App declaration | Stable ID, name, hostname, required permissions, health endpoint |
| Presentation | Shared styling, focused page layouts, forms, empty/error states, mobile layout |
| Mobile | Install manifest, icons, safe areas, touch/keyboard behavior, adaptive layouts, update handling |
| Human identity | Login, remembered sessions, logout/revocation, passkey enrollment and recovery |
| Machine identity | Separate request-only credentials and app-scoped API permissions |
| Jobs | Job ID, input schema, state, timestamps, bounded result/error, idempotency key |
| Approvals | Immutable request, requester, scope, expiry, explicit decision, single-use grant |
| Activity | Actor, application, action, resource, result, correlation ID |
| Notifications | Per-app device subscriptions, permission/preferences, durable delivery, request deep links |
| Operations | Packaging, service identity, health, logs, credentials, persistence and backup contract |

These are reusable capabilities, adopted as needed. A read-only app does not need
an approval model or a job queue. Domain tables and job history belong to the app
that owns them. Only deliberately shared services, such as a future identity
provider or notification delivery service, introduce cross-app runtime coupling.

Application-specific logic remains with its app. For example, container release
selection and GitHub PR content belong to System updates. SSH authentication and
connection lifetime enforcement belong to a connection gate.

Use explicit app declarations reviewed with the repository. Do not introduce
runtime-installed plugins or a generic endpoint accepting shell commands.

## Adding an application

An application contributes:

1. A declaration describing its hostname, UI name, permissions, and health check,
   plus a web app manifest with its own identity and icon when installable.
2. Screens and a typed backend API, plus domain-specific validation.
3. Named worker operations with typed inputs and explicit resources.
4. A Nix declaration for its identity, writable paths, credentials, schedules,
   and worker units.
5. Tests for its behavior, mobile acceptance checks, and an operations/backup note.

A manifest is metadata, not a grant of privilege. The Nix declaration and worker
implementation enforce which resources the app can access. Registering a new
operation must not automatically grant it to every machine client.

For example, the updates application might expose `scan-containers`,
`forecast-nix`, and `create-update-pr`. Its reporter keeps the GitHub token and
its existing service permissions. A future storage inspection tool would receive
its own worker and path permissions, rather than inheriting the reporter account.

Introduce reusable Nix options only while migrating these real services. Keep
nginx ownership in `hosts/nasa/services/nginx.nix`, as required by the current
architecture. App declarations supply routing metadata; nginx renders the vhosts.

## Mobile experience and distribution

Start with independently installable progressive web apps (PWAs). Each micro app
has its own Home Screen icon, standalone window, manifest ID, service-worker
scope, notification subscriptions, and remembered session. Users install only
the apps they want. Desktop browsers remain supported.

On iPhone, Home Screen web apps support Web Push from iOS 16.4 onward. Notification
permission requires a user gesture. They can display lock-screen notifications
and badges without joining Apple's Developer Program. Installation and permission
are explicit onboarding steps; an ordinary browser tab is not the same installed
notification experience. Verify these flows on the supported device/OS versions.

Treat the native feel as an acceptance criterion, not a consequence of adding a
manifest. Test launch behavior, touch targets, safe-area insets, scrolling,
navigation/back behavior, keyboard avoidance, dark mode, text scaling, and
loading/error states on an available iPhone. Design for future iPhone Duo
compatibility by testing compact and expanded viewports, orientation changes,
and preservation of the selected request and form state during resizing in
browser automation. Adapt to available space instead of relying on device names
or assuming a particular fold/posture API. Defer physical Duo validation until
hardware is available; it does not block initial delivery. Distinguish technical
compatibility from verified device-specific behavior in release notes.

Use a real-phone proof before making the PWA experience the permanent choice.
Browser automation and viewport emulation cover layout regressions, but cannot
prove iPhone installation, notification delivery, or operating-system feel.

| Delivery option | Update model | Intended use |
| --- | --- | --- |
| Installed PWA | Deploy web assets/API to NASA; service-worker updates handle installed clients | Initial default for dashboards and approval flows |
| Capacitor app | Reuse web UI in a native container; binary/plugin changes need a signed native build | Candidate if device integration is inadequate in the PWA |
| React Native/Expo app | Separate native UI; compatible JS/assets can use an update service, native changes need a new build | Candidate if native controls/behavior justify another client |

Capacitor is a deployment/integration option, not an automatic conversion to
native controls. Over-the-air updates are an additional deployment mechanism
with compatibility and distribution constraints; neither native option eliminates
binary signing and distribution. Select a sustainable iOS distribution method
before committing to a native client. Preserve API boundaries so that decision
does not require rewriting the backend.

PWA deployments need an explicit update strategy. Version and cache static
assets; avoid caching authentication and approval API responses. Show a controlled
refresh prompt when needed and keep old clients compatible through a rollout.
An update or offline restart must never replay an approval. Offline UI can show
connection status, but approving or claiming a grant requires a current server
response. HTTPS must be trusted by the device; verify the existing NAS private
certificate setup supports installation, service workers, and passkeys.

## Notifications

Ship notifications in the first useful mobile milestone. Provide a reusable
delivery component with app-scoped subscriptions, opt-in preferences, retry and
expiry handling, duplicate suppression, and removal of invalid subscriptions.
Begin with Web Push, with a transport interface that can later support native
push. A durable outbox records notification intent alongside the originating
transaction so a delivery failure does not lose the request.

Notification payloads contain minimal information suitable for a lock screen.
Tapping a notification opens its specific request in the relevant app, which
loads current state and requires the authenticated deliberate Approve/Deny
action. A notification or link is not an approval credential. Delayed, duplicated,
or missing notifications must not change authorization or resurrect expired
requests. An in-app pending list remains the source of truth; successful push
submission is not evidence of delivery or approval.

The NAS sends Web Push outbound to the browser vendor's push service. This need
not expose the app publicly. Opening the app and acting on the request still
requires the phone to reach the NAS over the LAN or Tailscale. Validate that
behavior away from home, including reconnecting after a notification arrives.

## Approval contract

The reusable approval model should support this lifecycle:

```text
pending --> denied
        --> expired
        --> approved --> expired
                     --> claimed --> completed / failed / expired
```

A decision binds an immutable request ID, authenticated requester, operation,
resource, permitted account, and maximum lifetime. Editing those details creates
a new request. Approval is a deliberate authenticated POST; opening a link or
rendering a preview never grants access.

Claiming an approval is atomic and single-use. The worker verifies both the grant
and its own local policy. A request-only automation identity cannot approve its
requests, edit decisions, enroll an approver, or obtain approval credentials.

Pending requests expire. Approved but unused grants expire independently.
Service restart and retries must not resurrect, duplicate, or silently broaden a
grant. Record decisions and claims without storing credentials or command output.

For NAS access, a grant authorizes one connection with a maximum lifetime.
Credential expiry alone does not close an established connection: the gate must
enforce the connection deadline and cleanup separately. Reconnecting requires a
new request and approval. SSH multiplexing must not create an unbounded grant.

The approval record is only the control-plane decision. The SSH gate needs its
own implementation and tests. Do not represent a working approval inbox as
proof that host access is approval-gated.

Before claiming enforcement, audit alternate routes from the development
container, including forwarded agents, the Rex host login, and any credentials
or APIs able to alter authorization. Preserve normal owner access from trusted
personal devices. Changes to existing host access require explicit review and
deployment authorization.

## Persistence and deployment

Each app owns its persistent state and migrations. Use a small transactional
database when needed; SQLite is a reasonable initial choice for one host if the
implementation tests concurrent decisions and uses atomic updates. Move an app
to PostgreSQL when its workload or multi-host requirements justify it. Apps do
not query one another's database files or share write credentials. Each app
declares its durable and disposable state explicitly.

Begin with existing systemd workers and timers. A process-wide asynchronous job
framework is unnecessary until an actual app needs it. The platform normalizes
job status and identifiers without forcing every worker into the same runtime.

Store secrets through agenix or systemd credentials, never in generated Nix store
files. Keep durable state in a documented location and provide a consistent
snapshot/dump for the existing Restic backup. Merely placing a live database in
an included directory is not a backup strategy.

Deploy through the repository's checked Nix workflow. Local previews, tests, and
configuration evaluation precede any change to the running host. Do not use SSH
to implement or deploy this proposal without explicit connection permission.

## Delivery sequence

1. **Runnable foundation:** reusable app scaffold, styling, service declaration,
   OpenAPI/client generation, and local development/CI conventions. Add optional
   human sessions and passkey enrollment/recovery components for apps that need
   them. No hub UI is required.
2. **Updates adoption:** apply the common deployment and styling conventions to
   System updates, retaining its focused interface, existing URL, reports,
   workers, and regression suite. Introduce authentication as a separately
   reviewable change; an auth gate must cover every reachable dashboard route,
   including legacy URLs, before claiming authenticated access.
3. **Mobile approval proof:** separate approval origin, requester identity,
   immutable request/decision records, remembered-browser Approve/Deny UI,
   installable PWA, and Web Push/deep links. Use a harmless test worker first.
   Include replay/expiry/concurrency tests. Verify install, background notification,
   tap-through, remembered sign-in, and approval on an available iPhone. Exercise
   compact/expanded layouts and state-preserving resize in browser automation
   for future Duo compatibility. Physical Duo testing is a deferred follow-up,
   not a milestone dependency. Review the feel on the available iPhone before
   deciding whether a native client is needed.
4. **NAS connection gate:** implement one-connection grants, server-enforced
   lifetime, failure cleanup, and the alternate-access review. Demonstrate that
   no approval means no usable connection. Deploy only after explicit review.
5. **Next real application:** use it to refine the declaration and deployment
   interface. Reuse the mobile and notification components where useful.

Each stage should be independently reviewable and runnable. Until stage four is
verified, retain the existing requirement for explicit permission before any
NASA SSH connection.

## References

- [Current repository architecture](architecture.md)
- [System updates behavior and deployment](updates.md)
- [Current NAS access workflow](nasa-access.md)
- [FastAPI features and API contracts](https://fastapi.tiangolo.com/features/)
- [Ionic React](https://ionicframework.com/docs/react/overview)
- [Web Push for iPhone Home Screen apps](https://webkit.org/blog/13878/web-push-for-web-apps-on-ios-and-ipados/)
- [Web Push delivery and service workers](https://webkit.org/blog/12945/meet-web-push/)
- [Capacitor updates](https://capacitorjs.com/docs/guides/deploying-updates)
- [Expo native/update compatibility](https://docs.expo.dev/eas-update/runtime-versions/)
