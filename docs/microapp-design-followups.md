# Micro-app design follow-ups

Owner feedback, recorded 2026-11-05 for the next design review.

- Fix the bright grey top bar in Approve's dark-mode phone interface. Check
  the installed iPhone app's status bar and safe area as well as the toolbar.
- Unify Approve and System updates through shared components, not only shared
  colors. Keep the apps independent; do not add a large navigation hub.
- Prefer brevity throughout the apps. Omit subtitles and explanations when the
  interface already makes the action or state obvious. Retain essential approval
  scope, limits, errors, and consequential confirmations.
- Explore Approve/Deny actions directly on approval notifications.

## Notification actions: feasibility

The existing service worker displays a notification and opens the request when
tapped; it does not implement decision actions.

As checked on 2026-11-05, WebKit's Notification interface still leaves `actions`
and `maxActions` unimplemented. Do not promise notification buttons for the
current iPhone PWA. Supporting web browsers can use notification actions with a
tap-to-open fallback; feature-detect support and verify on actual target devices.

Native iOS supports actionable notifications. A small native companion or shell
could provide Approve/Deny buttons while reusing the existing backend and much
of the web interface. This would require native push integration, device
authentication, app signing, and distribution; it is a separate architectural
decision, not a service-worker-only change.

For that design, require device unlock for approval, show enough request scope
to make the decision informed, authenticate decisions to the enrolled owner,
and retain server-side expiry, scope binding, and replay protection. Opening or
dismissing a notification must never approve. Handle expired requests and network
failures explicitly; do not queue approvals for later automatic execution.

References:

- [WebKit Notification interface](https://github.com/WebKit/WebKit/blob/main/Source/WebCore/Modules/notifications/Notification.idl)
- [Web notification actions](https://developer.mozilla.org/en-US/docs/Web/API/Notification/actions)
- [Apple actionable notifications](https://developer.apple.com/documentation/usernotifications/declaring-your-actionable-notification-types)
- [Require device unlock for an action](https://developer.apple.com/documentation/usernotifications/unnotificationactionoptions/authenticationrequired)

Notification actions are a recorded proposal, not implemented or deployed.

## Deployed design revision

The shared header, status, icon, empty-state, and native-control components now
serve both apps. Approve uses a compact request/detail view and a theme-matched
header; System updates uses the same controls and surfaces. Redundant subtitles
and empty-state explanations have been removed. Approval scope remains visible.

Deployed to NASA after explicit owner approval. The activated system is
`/nix/store/473mw12d9iis0l2fg6d0ldmg5yq7d5lw-nixos-system-nasa-26.05.20261102.7dcdd87`.
The previous system, available for rollback, is
`/nix/store/hqip1zc4k4rv5mrxv0bgk328640m339i-nixos-system-nasa-26.05.20261102.7dcdd87`.
Only `microapp-approvals.service` and `updates-dashboard.service` changed and
restarted. The maintenance connection was closed after verification.

Packaged builds, repository lint, and local browser flow checks passed. Both
services are running successfully, both live APIs respond, and all 18 deployed
frontend assets match the tested build. Live Chromium checks also verified the
dark header, phone layout, and scripts for each app without submitting actions.
Installed-iPhone status-bar behavior still needs a physical-device check. Native
notification actions remain deferred.
