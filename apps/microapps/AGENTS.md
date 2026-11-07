# Micro apps

Keep apps independent: separate origin, service identity, data, sessions, and
machine credentials. Approve and Updates share the private owner account service;
do not share their application databases or session cookies. Notifications keeps
device pairing. Account recovery is a local reset; do not add password-changing
or user-management screens.
Use the commands and acceptance checklist in README.md. New API payloads need
Pydantic models; regenerate openapi.json and web/src/api.d.ts together. Preserve
server-side permission checks even when the UI hides an action.

The request API cannot approve, enroll an owner, or execute host commands.
Never add a development login bypass to the production factory. Tests use an
isolated temporary server. Browser virtual authenticators do not establish that
push or platform behavior works on a physical iPhone. Duo hardware testing is
explicitly deferred; adaptive layout must work without device-name checks.

Do not enable deployment or open a NASA connection without the user's explicit
connection permission. A plan approval alone does not grant that connection.
