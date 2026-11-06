# Notification bridge

A generic native receiver for independent web apps. Services publish through one
versioned API; the iPhone companion displays notifications, opens service web pages,
and records simple choices or text replies. All forms, review screens, settings,
and service workflows stay on the web. Adding a service or changing its buttons
does not require a new native binary. New native capabilities and OS maintenance do.

The broker has its own identity, credentials, and SQLite database. It does not
depend on Home Assistant. Apple's APNs transports remote iPhone notifications.

## Contract

`openapi.json` is generated from Pydantic models. The `/v1` protocol supports:

- `POST /v1/notifications`: service-authenticated publish, scoped to configured
  recipients and HTTPS origins. A service/recipient/key tuple is idempotent;
  reusing it with changed content returns 409. There is a 1,000/day/service limit.
- `POST /v1/enroll`: consume a random, single-use, ten-minute operator grant.
  The recipient comes from the grant, never from the phone. Returns an independent
  device bearer credential, hashed at rest and saved in the phone's Keychain.
- `POST /v1/device/registration`: refresh an enrolled device's APNs token.
- `GET /v1/device/notifications/{id}`: current metadata for a device that received
  the notification. Other recipients/devices cannot retrieve it.
- `POST /v1/device/notifications/{id}/response`: atomically record one response
  across all recipient devices. Identical device retries are idempotent.
- `GET /v1/responses`, `POST /v1/responses/{id}/ack`: service-scoped response inbox.
  Unacknowledged responses repeat until acknowledged or expired.
- `POST /v1/device/settings`: create a one-minute, single-use web settings link.
  Its ticket is in the URL fragment, exchanged for a 15-minute HttpOnly, Secure,
  host-only session, then removed from browser history. Browser writes check Origin.
- `POST /v1/device/revoke`: disconnect the phone. Web settings and the local
  administrator also support revocation.

Example publish body (using a service credential in the Authorization header):

```json
{
  "recipient": "owner",
  "key": "backup-job-42-failed",
  "title": "Backup failed",
  "body": "Check the storage connection.",
  "url": "https://backup.example.com/jobs/42",
  "group": "backups",
  "ttl": 600,
  "actions": [
    {"id": "logs", "title": "Open logs", "kind": "open", "url": "https://backup.example.com/jobs/42"},
    {"id": "retry", "title": "Retry", "kind": "respond"},
    {"id": "note", "title": "Add note", "kind": "reply"}
  ]
}
```

Up to four actions are supported. iOS decides which actions are visible in each
presentation; expansion may be necessary. All response/reply actions require
device unlock. Opening/dismissing notifications never submits a response.
An optional `image` must use a configured service origin. The extension fetches it
without service credentials or cookies, rejects redirects, and limits it to 5 MB
of PNG/JPEG/GIF. Use a device-reachable image endpoint suitable for lock-screen
display. This version does not fetch private authenticated attachments.

`expires_at` optionally binds delivery/responses to an originating workflow's
absolute deadline; effective expiry is the earlier of that and `now + ttl`.
Payloads over APNs' 4 KB limit are rejected before enqueueing. Payloads include
display text, a notification ID, and the destination link: keep secrets and
approval credentials out of all three. Phone lock-screen privacy is controlled
by iOS settings.

## Response semantics

Responses are **authenticated input, not execution authority**. A service must:

1. Match the event's `key`, recipient, and action to its original operation.
2. Check its own authorization, current state, and the event's absolute expiry.
3. Atomically deduplicate using event `id` while recording the effect.
4. Acknowledge only after recording the effect (or a final rejection).

The native client sends one explicit response attempt and never persists decisions
for automatic offline retry. Expired responses disappear from the service inbox.
Polling is at least once, so consumers must enforce the deadline again at execution.
Do not use the generic recipient credential alone to authorize approval or host
access. Device-unlock options are enforced by the native UI, not independently
attested to the server. High-stakes actions should open the service's authenticated
web flow unless that service explicitly implements a suitable native trust model.

The included Approve adapter deliberately offers **Review**, opening the existing
passkey-authenticated request page. It cannot approve or claim a grant. The optional
outbox is inserted in the same transaction as the request. Existing Web Push
continues independently; configure browser subscriptions to avoid unwanted doubles.

## Delivery and native behavior

The systemd worker serializes delivery, recovers abandoned leases, retries transient
failures with backoff, and stops at expiry or eight attempts. APNs collapse IDs
coalesce retries. Revocation and opt-out stop future sends; delivered notifications
may remain on the lock screen. Provider acceptance is not a delivery/read receipt.
The persistent worker reuses its HTTP/2 client and refreshes its provider token
every 50 minutes, avoiding token churn from short-lived scheduled processes.
Invalid APNs tokens deactivate their device. Retained content and response text
are removed seven days after expiry during publish/delivery maintenance.

The app has only enrollment, connection status, a link to web preferences, and
disconnect. A normal tap opens the supplied HTTPS web URL directly, even when the
broker cannot be reached. Named actions use authoritative backend metadata.
Services remain responsible for web authentication and deep links.

A notification service extension fetches action definitions and images using the
shared Keychain credential. It registers categories dynamically before presentation.
If iOS skips/times out the extension, the original text and tap-to-open link still
work; rich actions/images may be absent. First-unlock behavior, dynamic category
registration, background responses, and image presentation require physical-device
validation. No background extension is required just to open a web page.

The phone must reach the broker for rich content and responses, and each web app
for its interface. The NASA route is private LAN/Tailscale HTTPS. Test with the
phone locked and away from home; delivery via APNs can succeed even when those
private routes cannot be reached. Reopen the companion after device registration
failures to retry registration.

## Development and checks

From the repository root:

```sh
nix develop .#notifications
export PYTHONPATH="$PWD/apps/notifications/backend"
pytest -q apps/notifications/backend/tests
python apps/notifications/export_api.py > apps/notifications/openapi.json
nix build .#notifications .#checks.x86_64-linux.notifications
```

On macOS, install Xcode and XcodeGen, then:

```sh
cd apps/notifications/ios
xcodegen generate
xcodebuild -project NotificationBridge.xcodeproj -scheme NotificationBridge \
  -configuration Debug -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' \
  CODE_SIGNING_ALLOWED=NO build
swiftc Shared/Protocol.swift Tests/ProtocolTests.swift -o /tmp/bridge-protocol-tests
/tmp/bridge-protocol-tests
```

The committed app icon is rendered from `ios/icon.svg` using `rsvg-convert` from the
notification development shell. Project/plist/entitlements files are generated by
XcodeGen and excluded from Git. The unsigned CI build and protocol tests run on
GitHub's `macos-15` image with Xcode 26.3. They do not prove physical iPhone behavior.

## One-time Apple and GitHub setup

Use the owner's existing Individual Apple Developer membership. This implementation
does not create Apple account resources or distribute a build automatically.

1. Register explicit App IDs `com.jmalexan.NotificationBridge` and
   `com.jmalexan.NotificationBridge.NotificationService` (or choose another base
   bundle ID consistently). Enable Push Notifications for the main app. Both
   targets share the main app's Keychain access group.
2. Create an App Store Connect record for the main app, and an internal TestFlight
   group including the owner. Complete Apple's required agreements/compliance.
3. Create an Apple Distribution certificate/private-key export (`.p12`) and App
   Store distribution profiles for **both** IDs. The main profile must include
   production push entitlement. Keep the certificate's private key in trusted
   signing storage; record certificate/profile expiration for renewal.
4. Create an App Store Connect API key usable for uploads, with only the needed
   upload role (for example App Manager). The workflow uses key ID, issuer ID,
   and `.p8`. An individual **membership** does not mean the workflow needs an
   individual-user API key without an issuer. If team API access is unavailable,
   resolve that Apple setup before configuring this issuer-based upload workflow.
5. Create GitHub environment **app-store**, restrict deployment branches to main,
   and require owner approval before secrets are released. This is separate from
   the infrastructure production environment. Set environment variables
   `APPLE_TEAM_ID` and optionally `BRIDGE_BUNDLE_ID`.
6. Add environment secrets `DISTRIBUTION_P12_BASE64`,
   `DISTRIBUTION_P12_PASSWORD`, `APP_PROFILE_BASE64`,
   `EXTENSION_PROFILE_BASE64`, `ASC_KEY_ID`, `ASC_ISSUER_ID`, and
   `ASC_PRIVATE_KEY_BASE64`. Base64 values must be single-line encodings of the
   original files. Transfer through GitHub's secret UI/API from a trusted machine;
   never paste keys into chat, PRs, source, or logs.
7. Once merged and approved for release, manually run **Notification iOS** on main.
   It imports signing assets into a temporary keychain, archives both targets,
   exports and uploads the IPA, and removes signing material even on failure.
   Assign the processed build to the internal TestFlight group in App Store Connect.

TestFlight builds expire 90 days after upload. Native changes need a new build;
service/web changes do not. Stable distribution remains a later decision (App Store
or an approved unlisted release). Do not rely on perpetual TestFlight expiry
refreshes as the long-term distribution plan.

## NASA provisioning and activation

The Nix module and private route are available but **disabled** until credentials
and identifiers exist. No host access is needed to review/build this change.

A trusted operator provisions root-only files (directories 0700, files 0600):

- `/var/lib/microapp-secrets/notifications/services.json`: independently random
  per-service tokens, origins, and recipient allowlists, for example:

  ```json
  {"approve":{"token":"REPLACE_WITH_RANDOM_32_PLUS_CHARACTERS","origins":["https://approve.nasa.jmalexan.com"],"recipients":["owner"]}}
  ```

- `/var/lib/microapp-secrets/notifications/apns.p8`: a dedicated APNs signing key
  with the appropriate app/topic/environment access. Keep it separate from the
  App Store Connect upload key. Its key ID and Apple team ID are public config.
- `/var/lib/microapp-secrets/approvals/notifications`: the same Approve publishing
  token as in services.json, readable by the approval adapter via LoadCredential.

Then propose the activation configuration in a separate release:

```nix
services.notificationBridge = {
  enable = true;
  origin = "https://notifications.nasa.jmalexan.com";
  servicesFile = "/var/lib/microapp-secrets/notifications/services.json";
  apnsKeyFile = "/var/lib/microapp-secrets/notifications/apns.p8";
  apnsKeyId = "APPLE_KEY_ID";
  appleTeamId = "APPLE_TEAM_ID";
};
services.approvals.notifications.enable = true;
```

Ensure private DNS resolves the hostname and the existing TLS certificate covers
it. Only the broker worker needs outbound APNs HTTPS; no new public inbound route
is added. Do not relax robots' private-network policy to provision or test it.

The enabled module installs `notification-admin`. The operator runs `notification-admin --database
/var/lib/microapp-notifications/state.sqlite enroll --recipient owner` as
an account authorized to access that database.
Deliver the printed ten-minute code privately to the owner. Enter the HTTPS origin
and code in the companion. Do not place this output in agent logs. A local operator
can revoke a device with the same command's `revoke --device ID` subcommand.

Database snapshots join NASA's existing Restic backup chain when enabled. Back up
credentials through the existing encrypted workflow. After restoring a database,
stop web/delivery services and run `notification-admin --database
/var/lib/microapp-notifications/state.sqlite reset-devices --confirm-reset` before
restarting; then enroll again. This revokes all devices and clears restored
grants/sessions/tickets, disables deliveries, and acknowledges old responses.
This prevents revoked credentials or old pending notifications being resurrected.
Do not execute restored generic responses without checking the originating state.

## Physical acceptance before relying on it

Verify enrollment/code replay rejection, TestFlight production APNs delivery,
tap-to-open with broker unavailable, dynamically changed button labels without
reinstalling, response unlock, text reply, image fallback, LAN/Tailscale reachability,
expiry, duplicate responses across devices, preferences, revocation, token renewal,
and a real Approve Review link followed by the existing passkey decision flow.

References: [APNs requests](https://developer.apple.com/documentation/usernotifications/sending-notification-requests-to-apns),
[action categories](https://developer.apple.com/documentation/usernotifications/declaring-your-actionable-notification-types),
[TestFlight](https://developer.apple.com/help/app-store-connect/test-a-beta-version/testflight-overview/).
