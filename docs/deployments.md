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

### Validation reuse

PR validation records its actual tested merge commit and source tree in a small
`validated-tree-ATTEMPT` artifact, retained for 14 days. On main, the Check and
Notification iOS workflows can reuse a successful run of the corresponding PR
workflow. The lookup requires a merged, same-repository PR associated with the
current main commit, the same PR-head source tree (including workflow and helper
code), and the same tested merge tree. It verifies the recorded merge commit and
its PR-head parent through GitHub's API. A new commit ID after merging is fine;
changed source files are not. This assumes validation depends on source content,
not the commit ID or timestamp; revisit reuse if checks start using Git metadata.

Missing/expired artifacts, unavailable APIs, forks, changed trees, and runs outside
the latest 50 successful PR runs all fall back to full validation. Runs from before
this feature have no artifact and cannot be reused. The Actions summary links the
reused run or states that full validation is running. PR jobs always validate;
only superseded PR validation jobs are canceled. Main and manual runs are never
canceled by this optimization.
Select `full_validation` on a manual workflow dispatch to force fresh checks.

Main always computes its own deployment plan against the push's previous commit.
PR records can also supply the evaluated new host derivation paths, under the same
verified-run and source-tree requirements. These are comparison metadata; no host
selection, build outputs, or executable code is taken from a PR artifact. The
required `nix` job, production branch restrictions, exact main deployment revision,
and per-host activation serialization remain in place.
Manual TestFlight runs may reuse simulator validation but always create and upload
a fresh signed device archive.

### Deployment planning cache

Successful main validation saves a small JSON record of NASA/HTPC and Linux check
derivation paths through Actions cache. Subsequent runs restore the entry for their exact
base source tree. Only main saves shared entries; PRs can read them but write
their new-tree result only into the verified validation artifact. The planner
checks source tree, planner-code hash, Nix version, platform, runner image, schema, both host
names, and derivation-path syntax before accepting a record. Cache keys include
the same evaluation context and source tree, with no broad restore-key fallback.
Changing the planner, evaluation environment, or source invalidates the result.
The first main run after rollout evaluates its uncached base and seeds the next
run's entry; fully cached planning is available after that.

With a cached base and verified PR head, planning compares two maps without Nix
evaluation. Missing, malformed, or incompatible records trigger normal evaluation;
cache service failures do not block a release. Each cold revision evaluates both
hosts together in one Nix process. Identical source trees are evaluated at most
once per invocation, and forced reconciliations omit the unused base evaluation.
`full_validation` bypasses both cached maps and PR derivation reuse. The planner
logs reuse and evaluation timings. This caches metadata only, not the Nix store;
it retains the source-content assumption above and does not change protections.

If a deployment fails, resolve or retry it before merging the next release.
Host selection describes changes between commits, not proof of the host's live
state. An owner can retry/reconcile `nasa`, `htpc`, or `all` through **Actions →
Check → Run workflow**, on **main**. Branch dispatches never deploy. A retry does
not require forwarding an SSH agent. Recovery from broken CI, networking, or
host SSH can still need the authorized maintenance path in `nasa-access.md`.
Keep one release in flight at a time. Deployment jobs serialize per host and
never cancel an activation already running; GitHub may replace an older pending
job if several releases are queued.

### Single host evaluation

Repository checks build on the runner without a persistent Nix store cache or a
main-branch warming job. The measured net PR saving of roughly a minute did not
justify restoring multi-gigabyte archives and rebuilding/uploading them on main.
The small deployment-derivation cache and verified PR validation reuse remain.

On a full validation, `deployment-plan.py --validate` archives the exact head,
checks its non-host flake outputs on every system through a temporary wrapper,
then evaluates and type-checks both NixOS toplevel derivations together. The
wrapper forwards the original outputs and their original `self`; it omits only
`nixosConfigurations`, whose validation belongs to the planner. Unexpected or
missing host names fail validation. This avoids repeating host evaluation;
`nix flake check` itself does not use Nix's evaluation cache. Valid cached metadata
never bypasses a requested validation. Failed validation publishes no new record.
With verified PR reuse, main still compares only validated derivation metadata.

### Conditional VM checks

On PRs, each VM check runs only when its derivation differs from the exact base's
successful main-validation record. This covers `approval-ssh-gate`, `agent-network`,
`agent-guest`, and `robots-backup` independently. Nix captures their transitive source and package
dependencies, so this does not rely on filename filters. The same evaluation
records all Linux check derivations for possible future selection, but lint,
backend tests, and frontend checks still run on every PR. The required `nix` job
always runs, and its summary shows the VM checks selected or inherited from base.

A freshly evaluated base is not proof that its checks passed. Missing, expired,
invalid, or incompatible main metadata runs every VM check, even if a fresh base
evaluation yields unchanged paths. Full validation, manual runs, and main runs
without verified PR reuse also run every VM check. The runner defaults to all
checks when invoked locally and rejects invalid selections. No test binaries or
Nix store outputs are cached or restored.

The first PR after rollout runs every VM check; merging a successful validation
seeds the new metadata schema for subsequent PRs. Updating the planner, Nix,
platform, or runner image likewise falls back to full VM coverage. Deployment
health checks and live update polling are never skipped by this selector.

### Local production build reuse

After successful NASA activation and health checks, CI queues a fresh container
release/digest scan with `systemctl --no-block restart`. This refreshes installed
versions and clears completed update PRs from the dashboard without waiting for
registry polling in the deployment job. Restarting ensures an already-running
scan cannot leave only pre-activation results. Queue failures fail the step;
scan completion and errors remain visible through the reporter's journal and
dashboard. The scan is no longer wanted by `multi-user.target`, so NixOS switches
do not synchronously start it. Daily and manual refresh remain available.
This automatic post-activation refresh applies to the CI deployment workflow;
an out-of-band manual switch can request the same scan explicitly.

NASA continues to build and activate the exact main revision locally. Its
persistent Nix store already reuses unchanged build outputs between deployments.
Changed guest closures require a new isolated EROFS image, so robots now uses
ordinary LZ4 instead of LZ4 high compression, with workers bounded by
`NIX_BUILD_CORES`. The guest keeps its private store and existing readiness checks.
Changing compression rebuilds the image and restarts robots once on rollout;
subsequent host-only changes can reuse the image when the guest closure is stable.

A local benchmark on robots (2026-11-07), using the installed guest's 891 store
paths, two compression workers, and the production tail-packing/fragment flags,
ran LZ4 HC, LZ4, LZ4, then LZ4 HC against the same read-only bind-mounted closure:

| Compression | First run | Second run | Image bytes |
| --- | ---: | ---: | ---: |
| LZ4 HC | 53.18 s | 52.63 s | 1,501,843,456 |
| LZ4 | 13.37 s | 14.64 s | 1,629,032,448 |

This reduces image creation time by roughly 74% for an 8.5% larger image. It is
an image-generation benchmark on the VM, not a measured end-to-end deployment
speedup on NASA. Dependency resolution, changed derivation builds, activation,
and guest readiness still take time. NASA's memory-protecting build concurrency
limits remain in place.

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

The active policy is recorded in `.github/rulesets/`:

- `main`: require a PR, one approval from the code owner, approval after the last
  push, dismissal of stale approvals, the up-to-date `nix` check from GitHub
  Actions, and resolved review threads. Prohibit deletion and force pushes for
  non-exempt actors. `Repository admin` has **Always allow** bypass.
- `.github/CODEOWNERS`: `* @jmalexan` covers every file, including CODEOWNERS itself.
- `Owner merges releases`: disabled. Its
  `Restrict updates` rule blocked auto-merge because it required a bypass even
  when reviews and checks passed. Changing its bypass mode did not fix that.

This is a personal-account repository. On 2026-11-06 the live collaborators API
listed only `jmalexan`, with role `admin`; the bot has no administration access.
Thus the administrator exception currently covers only the owner. Revisit this
assumption if ownership or access changes. The owner may push directly to main
or manually merge their own PR without self-approval. GitHub does not support
approving your own PR, and auto-merge should not be expected to invoke a bypass
for an owner-authored PR; use a manual merge for that case.

## Policy activation and recovery

The transition completed on 2026-11-06. PR #58 installed CODEOWNERS on main;
GitHub reports no syntax or owner errors. The owner saved the replacement main
rule at 06:16:35 UTC and disabled the old update-only rule at 06:17:19 UTC.
Read-only API checks confirmed one approval, code-owner review, stale-review
dismissal, last-push approval, conversation resolution, and the up-to-date `nix`
check bound to GitHub Actions (integration `15368`). Effective rules contain no
`update` restriction, and the bot reports `current_user_can_bypass: never`.
The owner confirmed the **Repository admin → Always allow** exception; the bot's
read-only ruleset response omits bypass actors. Repository auto-merge is enabled.

The JSON files are recovery payloads; committing them does not configure GitHub.
When recreating protections, install CODEOWNERS and the replacement review/check
requirements before retiring any prior gate. The bot has no Administration
permission. The owner applies settings from their trusted GitHub session; agent
use of the owner's bypass credentials is not authorized. Normal agent operations
continue through `github-bot`.

The reviewed API payloads are in `.github/rulesets/`. The production environment
allows only the `main` branch. Its existing SSH and Tailscale secrets remain in
that environment; they are not copied into the container or exposed to PR checks.

These controls cover routine GitHub releases. The previously documented owner
SSH, Rex, LAN, and other service credentials are separate access paths; see
`access-review.md`. Do not claim that these changes lock down every host route.

References: [GitHub rulesets](https://docs.github.com/en/repositories/configuring-branches-and-merges-in-your-repository/managing-rulesets/available-rules-for-rulesets),
[installation tokens](https://docs.github.com/en/apps/creating-github-apps/authenticating-with-a-github-app/generating-an-installation-access-token-for-a-github-app).

## Setup status

The `main` ruleset (`20579942`) is active with the owner-exempt approval policy.
The obsolete owner-merge ruleset (`26669022`) is disabled. Recheck live settings
when diagnosing a merge problem; do not infer their state from committed JSON.
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
