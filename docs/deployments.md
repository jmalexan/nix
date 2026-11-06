# PR releases

The bot proposes releases through PRs. After the policy transition below, the
owner approves the final changes and auto-merge can finish when checks pass.
The owner is exempt: personal direct pushes and manual PR merges are allowed.
Descriptions remain concise release summaries, not an expectation of detailed
code review. No routine SSH agent forwarding is needed.

## Release flow

1. Work on a branch and run the relevant checks.
2. Push with `nix run .#github-bot -- git push -u origin BRANCH`.
3. Open the PR with `nix run .#github-bot -- gh pr create --reviewer jmalexan
   --title '...' --body-file /tmp/release.md`. Include the behavior change,
   target hosts, validation, and expected interruption. The review request is
   the owner's GitHub notification; notification delivery follows their settings.
4. Enable auto-merge when the owner requests it. The owner approves the final
   changes; new changes invalidate the approval. The bot cannot supply the
   required code-owner approval.
5. GitHub merges after owner approval, required `nix` checks, and resolved review
   threads. The check summary lists the deployment plan. The owner can instead
   manually merge using their administrator exemption. GitHub Actions deploys
   the exact main revision using the existing production identity.
6. Monitor the Actions run. Its deployment jobs verify activation and report the
   result in GitHub's production deployment history.

Host selection compares evaluated NixOS system derivations for the base and new
commits, not a hand-maintained list of filename prefixes. NASA-only changes do
not wake HTPC. Shared changes can deploy both. Docs-only changes deploy neither.
The selected host's whole NixOS configuration is activated, including its apps.

If a deployment fails, resolve or retry it before merging the next release.
Host selection describes changes between commits, not proof of the host's live
state. An owner can retry/reconcile `nasa`, `htpc`, or `all` through **Actions →
Check → Run workflow**, on **main**. Branch dispatches never deploy. A retry does
not require forwarding an SSH agent. Recovery from broken CI, networking, or
host SSH can still need the authorized maintenance path in `nasa-access.md`.
Keep one release in flight at a time. Deployment jobs serialize per host and
never cancel an activation already running; GitHub may replace an older pending
job if several releases are queued.

## Bot identity

The private GitHub App is installed on **only `jmalexan/nix`**. Permissions:

| Permission | Access | Purpose |
| --- | --- | --- |
| Contents | Read/write | Push feature branches |
| Pull requests | Read/write | Open/update PRs and request owner review |
| Workflows | Read/write | Propose workflow changes through PRs |
| Actions | Read | Read CI and deployment results |
| Checks | Read | Read check results |
| Metadata | Read | Required GitHub metadata access |

It has no Administration, Secrets, Environments, Deployments, or Actions write
permission. Workflow-writing permission can propose changes, but production
secrets are available only on main. Bot changes require owner approval before
merging; the owner's personal updates are exempt.

`tools/github-bot.py` signs an App JWT and requests a token scoped to this single
repository and the listed permissions. Tokens are passed through the child
process environment, never command arguments or Git remote URLs, and revoked
when the command exits. GitHub's one-hour expiry is the fallback if revocation
fails. Each invocation uses an empty temporary gh configuration and overrides
Git's credential helpers; owner tokens are not a fallback. GitHub SSH remotes
are rewritten to HTTPS and SSH is disabled inside the wrapper.

One-time configuration, after creating/installing the App and securely transferring
its downloaded private key to a temporary file in the container:

```sh
nix run .#github-bot -- configure --app-id APP_ID --key-file /path/to/key.pem
nix run .#github-bot -- status
```

The helper validates the installation and permissions before storing the key in
`~/.local/share/nasa-github-app/private-key.pem` (0600, parent 0700). It refuses to
replace an existing identity. This is a GitHub App signing key, not a NAS SSH key.
Remove the transferred temporary copy after configuration. Never put the key in
the repository, an issue, a PR, or chat. The existing `home` environment remains
personal and keeps its owner credentials. Agent execution moves to the separate
[agent VM](agent-vm.md), which receives only the scoped bot identity. Do not delete
or revoke personal credentials as part of that migration.

## Repository protections

The desired policy is recorded in `.github/rulesets/`:

- `main`: require a PR, one approval from the code owner, approval after the last
  push, dismissal of stale approvals, the up-to-date `nix` check from GitHub
  Actions, and resolved review threads. Prohibit deletion and force pushes for
  non-exempt actors. `Repository admin` has **Always allow** bypass.
- `.github/CODEOWNERS`: `* @jmalexan` covers every file, including CODEOWNERS itself.
- `Owner merges releases`: disabled after the replacement is active. Its
  `Restrict updates` rule blocked auto-merge because it required a bypass even
  when reviews and checks passed. Changing its bypass mode did not fix that.

This is a personal-account repository. On 2026-11-06 the live collaborators API
listed only `jmalexan`, with role `admin`; the bot has no administration access.
Thus the administrator exception currently covers only the owner. Revisit this
assumption if ownership or access changes. The owner may push directly to main
or manually merge their own PR without self-approval. GitHub does not support
approving your own PR, and auto-merge should not be expected to invoke a bypass
for an owner-authored PR; use a manual merge for that case.

## One-time policy transition

The JSON files describe the requested policy; committing them does not configure
GitHub. Activate in this order so bot changes always require a human decision:

1. Merge PR #58, which installs `.github/CODEOWNERS` on main, using the existing
   owner bypass checkbox once checks pass. The old update-only gate stays active
   during this bootstrap release.
2. In [main settings](https://github.com/jmalexan/nix/settings/rules/20579942),
   add **Repository admin → Always allow** to the bypass list. Under required
   pull requests, require **1 approval**, **code-owner review**, **dismiss stale
   approvals**, and **approval of the most recent reviewable push**. Keep the
   required `nix` check, up-to-date branches, and resolved review threads. Save.
3. Verify CODEOWNERS is recognized on main and the new rules are active, then
   set [Owner merges releases](https://github.com/jmalexan/nix/settings/rules/26669022)
   to **Disabled**. Do not disable it before the replacement is in place.
4. Verify a subsequent bot PR requires the owner's review and passing checks,
   has no update restriction, and can auto-merge after those requirements pass.

The bot has no Administration permission, so the owner applies steps 2–3 from
their trusted GitHub session. Agent use of the owner's bypass credentials is not
authorized. Normal agent operations continue through `github-bot`.

The reviewed API payloads are in `.github/rulesets/`. The production environment
allows only the `main` branch. Its existing SSH and Tailscale secrets remain in
that environment; they are not copied into the container or exposed to PR checks.

These controls cover routine GitHub releases. The previously documented owner
SSH, Rex, LAN, and other service credentials are separate access paths; see
`access-review.md`. Do not claim that these changes lock down every host route.

References: [GitHub rulesets](https://docs.github.com/en/repositories/configuring-branches-and-merges-in-your-repository/managing-rulesets/available-rules-for-rulesets),
[installation tokens](https://docs.github.com/en/apps/creating-github-apps/authenticating-with-a-github-app/generating-an-installation-access-token-for-a-github-app).

## Setup status

The original `main` (`20579942`) and owner-merge (`26669022`) rulesets are active
as of preparation. The replacement owner-exempt approval policy above is pending
the one-time transition; do not treat it as live based on this document alone.
The production environment now allows only the `main` branch (policy `65695987`);
its four existing deployment secrets were preserved. GitHub App `5637230`,
installation `179132993`, is configured and restricted to `jmalexan/nix`. Bot
authentication, branch push, and PR creation were verified.
[PR #57](https://github.com/jmalexan/nix/pull/57) merged on 2026-11-06 as
`b07032a45e680bba92e1b7de08f6e92a8e701b2a`.
[Production run 42166728888](https://github.com/jmalexan/nix/actions/runs/42166728888)
passed its checks and deployed NASA successfully. HTPC was not selected. The
`robots` VM booted, enrolled as `tag:agent`, and passed readiness, authenticated
Rex login, scoped bot, and preloaded-context checks.

The local SSH key matches owner GitHub key ID `148267959`. It and the owner gh
login remain in personal `home`, and must not be copied to the agent VM. Sessions
still running in `home` remain in the personal trust boundary until moved. The
key does not match tracked NAS authorized keys; no SSH connection was attempted
during this audit.

Validation of the prepared framework passed: all-system flake evaluation, packaged
lint/backend/frontend/SSH-gate checks, workflow syntax, and nine deployment-plan
and bot-authentication tests. Comparing this branch with GitHub main selects
only NASA. The existing local App UI and connection-gate commits are included in
the release branch so a later GitHub deployment preserves what is already live.
