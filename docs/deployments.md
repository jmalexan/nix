# PR releases

Routine deployments use GitHub. The bot prepares a PR; the owner clicks **Merge
pull request** when ready to release. The description is a release summary, not
an expectation of detailed code review. There is no additional review-approval
button and no routine SSH agent forwarding.

## Release flow

1. Work on a branch and run the relevant checks.
2. Push with `nix run .#github-bot -- git push -u origin BRANCH`.
3. Open the PR with `nix run .#github-bot -- gh pr create --reviewer jmalexan
   --title '...' --body-file /tmp/release.md`. Include the behavior change,
   target hosts, validation, and expected interruption. The review request is
   the owner's GitHub notification; notification delivery follows their settings.
4. Wait for the required `nix` check. Its summary lists the host deployment plan.
5. The owner merges. GitHub Actions deploys the exact merged revision using the
   existing production identity. The bot cannot merge into main or push to it.
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
secrets are available only on main and main updates require the owner's merge.

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
the repository, an issue, a PR, or chat. After validating the bot, remove the old
owner gh login from the container and verify no owner credential remains as an
alternate Git authentication path. The owner's personal device login is separate.

## Repository protections

Two independent rulesets apply to main:

- `main`: require a PR, the up-to-date `nix` check from GitHub Actions, and resolved
  review threads; prohibit deletion and force pushes. No bypass actors. No formal
  approving-review count is required.
- `Owner merges releases`: restrict updates, with only repository administrators
  allowed to bypass **through a PR**. The bot is not an administrator or bypass
  actor. This rule is separate so the owner's merge still obeys the checks above.

The reviewed API payloads are in `.github/rulesets/`. The production environment
allows only the `main` branch. Its existing SSH and Tailscale secrets remain in
that environment; they are not copied into the container or exposed to PR checks.

These controls cover routine GitHub releases. The previously documented owner
SSH, Rex, LAN, and other service credentials are separate access paths; see
`access-review.md`. Do not claim that these changes lock down every host route.

References: [GitHub rulesets](https://docs.github.com/en/repositories/configuring-branches-and-merges-in-your-repository/managing-rulesets/available-rules-for-rulesets),
[installation tokens](https://docs.github.com/en/apps/creating-github-apps/authenticating-with-a-github-app/generating-an-installation-access-token-for-a-github-app).

## Setup status

The `main` ruleset (`20579942`) and owner-merge ruleset (`26669022`) are active.
The production environment now allows only the `main` branch (policy `65695987`);
its four existing deployment secrets were preserved. Bot App registration and
credential cutover are still pending. The workflow changes are on the
`pr-deployments` branch and are not active on main yet.

The local SSH key also matches owner GitHub key ID `148267959`. Along with the
owner gh login, it must be retired from this container before claiming that local
automation has only the bot's restricted identity. It does not match the tracked
NAS authorized keys; no SSH connection was attempted during this audit.
