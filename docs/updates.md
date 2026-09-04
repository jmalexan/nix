# System updates

## Forecast dashboard

The NAS hosts the internal **System updates** dashboard at
`https://updates.nasa.jmalexan.com`. The nginx vhost admits only clients on the
LAN or Tailscale. It presents update information as a service inventory rather
than exposing Updatecli's source/target/action execution model.

The main page shows:

- **Containers**, with installed and newest compatible tags, pinned-digest
  status, scan times, and upstream release-note links where a release maps to a
  GitHub tag.
- **Nix package forecast**, with the version-only closure differences for
  `nasa` and `htpc` after a temporary flake update.
- **GitHub Actions**, with the major or semantic version channels used by the
  repository workflows.
- A collapsed history of the most recent 100 scans.

Three jobs populate four normalized JSON reports under
`/var/lib/updates-dashboard-reporter`:

- The **container scan** first compares every image declared through
  `virtualisation.oci-containers` with the newest policy-compatible registry
  tag, then checks whether the digest behind each current tag still matches the
  digest committed in Nix. It preserves fixed database majors and the Frigate
  TensorRT variant, fetches only selected manifests, and retries transient
  registry failures. The two passes remain separate reports so a partial
  registry failure is visible without requiring separate jobs or controls.
- The **Nix flake forecast** clones `main`, updates a temporary `flake.lock`,
  builds the current and candidate `nasa` and `htpc` closures, and records
  `nix store diff-closures` output.
- The **GitHub Actions scan** clones `main`, finds versioned external actions in
  workflow files, and compares their current refs with upstream Git tags.

All three jobs run at boot and daily. The Nix closure forecast starts at
05:00 with up to one hour of jitter. It is intentionally limited to one Nix
build job and can download candidates into the NAS store. The dashboard's Nix
button asks for confirmation because this scan is materially heavier than the
registry and Git tag lookups.

Each section has an on-demand scan control. These controls write a fixed trigger
file consumed by a corresponding systemd path unit; the web process is not
allowed to invoke arbitrary commands or start arbitrary units. The equivalent
shell commands are:

```console
sudo systemctl start updates-dashboard-containers-report.service
sudo systemctl start updates-dashboard-actions-report.service
sudo systemctl start updates-dashboard-nix-report.service
```

Inspect a failure with `journalctl -u <service>`. Check the web application with
`systemctl status updates-dashboard.service` or `curl http://127.0.0.1:8091/health`.
Report files are disposable operational state: a successful timer run recreates
the current view.

## Pull-request setup

The System updates dashboard can create reviewable pull requests for a displayed
container, every currently reported container change, a flake-input update, or
a GitHub Action update. Container PRs resolve and commit immutable digests; the
two Immich application images remain grouped. **Create PR for all** puts every
reported container version and digest change into one reviewable pull request.
Nix PRs run `nix flake update` against the latest `main`. No dashboard action
merges a PR or deploys a host. While the dashboard has a currently relevant open
PR link, a lightweight job reconciles its state with GitHub every ten seconds.
It makes no GitHub request when there are no such links. Closing a PR without
merging changes its control to **Create new PR**; a replacement uses a fresh
branch even when the proposed diff is unchanged.

Create a fine-grained GitHub personal access token restricted to the
`jmalexan/nix` repository. Grant **Contents: read and write**, **Pull requests:
read and write**, and **Workflows: read and write** (the latter permits Action
update branches to modify `.github/workflows`). Replace the committed encrypted
empty placeholder with the token:

```console
nix develop
agenix -e secrets/updates-dashboard-github-token.age
```

Enter only the token in the editor, then commit the changed encrypted file. On
deployment, agenix decrypts it to `/run/agenix` as mode `0400`, owned by
`updates-dashboard-reporter`. The web server can detect whether the decrypted
file is non-empty but cannot read it. Only the short-lived PR worker runs as
`updates-dashboard-reporter` and can read the credential. Replacing the secret
with an encrypted empty value disables PR creation.

The dashboard is deliberately reachable only from the existing LAN and
Tailscale allowlist. Mutating requests require a same-origin session token to
prevent cross-site requests, but there is no per-user login: anyone admitted by
that network allowlist can intentionally launch scans and request PRs.

## Review workflow

1. Review the update and its linked release notes in System updates, then choose
   **Create PR**.
2. Open the resulting PR, review the generated diff, and wait for the Nix check
   workflow.
3. For a NixOS host, run `nix run .#package-diff -- nasa` or `-- htpc` to compare
   the proposed closure with the currently deployed `main` branch.
4. Merge the PR. After checks pass, GitHub Actions deploys that exact commit to
   `nasa` and `htpc`; `Book` is deliberately activated by hand with
   `update-now`.
5. Verify the affected service and keep the previous generation until the
   change has settled.

The System updates dashboard covers flake inputs, GitHub Actions, and the
container declarations evaluated from the `nasa` NixOS configuration. It does
not provide meaningful
version PRs for unversioned Homebrew formula/cask declarations; those follow
Homebrew when the Mac is upgraded separately.

## Deployment

Successful pushes to `main` deploy the exact checked commit to both NixOS hosts.
Pull requests only run checks. The workflow can also be run manually to redeploy
the current `main` revision. Deployments are serialized per host so two
activations cannot overlap.

Because `htpc` suspends while idle, its deployment job first asks the always-on
`nasa` host to send a Wake-on-LAN packet, then waits for the HTPC's SSH service.
The HTPC's wired interface has magic-packet wake enabled declaratively; the
firmware's Wake-on-LAN setting must remain enabled as well. If the job had to
wake the HTPC, it schedules another suspend after a successful activation. An
HTPC that was already awake before deployment is left awake.

The `production` environment provides `TS_OAUTH_CLIENT_ID`, `TS_OAUTH_SECRET`,
`DEPLOY_SSH_PRIVATE_KEY`, and `DEPLOY_SSH_KNOWN_HOSTS`. The Tailscale OAuth
client creates an ephemeral `tag:ci` node; the tailnet policy restricts that tag
to TCP port 22 on the two deployment targets.

To rotate the SSH identity, replace the public key in `modules/ssh-deploy.nix`,
deploy it before removing the old key, then replace the environment secret. From
a machine with GitHub CLI access, install the SSH values without printing the
private key:

```console
gh secret set --repo jmalexan/nix --env production \
  DEPLOY_SSH_PRIVATE_KEY < .local/github-actions-deploy
ssh-keyscan -t ed25519 nasa htpc | \
  gh secret set --repo jmalexan/nix --env production DEPLOY_SSH_KNOWN_HOSTS
```

## Adding a container image

Declare an exact image tag and digest:

```nix
image = "ghcr.io/example/application:1.2.3@sha256:…";
```

Use an exact upstream release tag when one is practical. Use a rolling channel
only when that is intentional, and retain the digest pin. Add any compatibility
policy to `versionFilter` in `hosts/nasa/services/updates-dashboard.nix`. When an
upstream release has stable GitHub tags, add a `containerMetadata` entry there
to expose exact release-note links. Use `updateGroup` for images that must be
updated in one PR.
