# Update dashboard and Renovate

## Udash forecast dashboard

The NAS hosts an internal Updatecli/Udash trial at
`https://updates.nasa.jmalexan.com`. The nginx vhost admits only clients on the
LAN or Tailscale because this first version does not configure an identity
provider. Do not expose it through the router: unauthenticated Udash mode also
leaves its report-write API open.

Three read-only Updatecli pipelines populate the dashboard:

- **OCI release forecast** compares every image declared through
  `virtualisation.oci-containers` with the newest policy-compatible registry
  tag. It preserves fixed database majors and the Frigate TensorRT variant.
- **OCI pinned digest drift** checks whether the digest behind every current
  tag still matches the digest committed in Nix.
- **Nix flake update forecast** updates a temporary copy of `flake.lock`, builds
  the current and candidate `nasa` and `htpc` closures, and records the exact
  package/version changes from `nix store diff-closures`.

The OCI reports run daily. The more expensive Nix closure forecast runs weekly;
it can download candidates into the NAS Nix store, but it never changes the
repository, opens a pull request, or deploys a host. Run any report immediately
with:

```console
sudo systemctl start updates-dashboard-oci-releases-report.service
sudo systemctl start updates-dashboard-oci-digests-report.service
sudo systemctl start updates-dashboard-nix-report.service
```

Inspect failures with `journalctl -u <service>` and check the three containers
with `docker ps --filter name=updates-dashboard`. Report history lives in the
Udash PostgreSQL directory but is deliberately excluded from Restic during the
trial; the next timer run reconstructs the current view.

The dashboard is observational for now. Renovate remains responsible for
editing files and opening reviewable pull requests. If Updatecli eventually
replaces it, add authenticated SCM credentials and explicit targets only after
the read-only reports have demonstrated reliable version policies.

## Initial setup

Install the hosted Renovate GitHub App and grant it access to this repository.
After it reads `renovate.json5`, Renovate creates a Dependency Dashboard issue.
That issue is the UI for pending, rate-limited, ignored, and approval-gated
updates. The first run may primarily open digest-pinning PRs; those establish an
immutable baseline for later image updates.

## Review workflow

1. Open the Dependency Dashboard and select any approval-gated major updates
   that should receive a PR.
2. Review the generated diff and wait for the Nix check workflow.
3. For a NixOS host, run `nix run .#package-diff -- nasa` or `-- htpc` to compare
   the proposed closure with the currently deployed `main` branch.
4. Merge the PR. After checks pass, GitHub Actions deploys that exact commit to
   `nasa` and `htpc`; `Book` is deliberately activated by hand with
   `update-now`.
5. Verify the affected service and keep the previous generation until the
   change has settled.

Renovate updates flake inputs, GitHub Actions, and Nix container declarations
carrying a `# renovate:` annotation. It does not provide meaningful version PRs
for unversioned Homebrew formula/cask declarations; those follow Homebrew when
the Mac is upgraded separately.

## Deployment

Successful pushes to `main` deploy the exact checked commit to both NixOS
hosts. Pull requests only run checks. The workflow can also be run manually to
redeploy the current `main` revision. Deployments are serialized per host so
two activations cannot overlap.

Because `htpc` suspends while idle, its deployment job first asks the always-on
`nasa` host to send a Wake-on-LAN packet, then waits for the HTPC's SSH service.
The HTPC's wired interface has magic-packet wake enabled declaratively; the
firmware's Wake-on-LAN setting must remain enabled as well. If the job had to
wake the HTPC, it schedules another suspend after a successful activation. An
HTPC that was already awake before deployment is left awake.

The `production` environment provides `TS_OAUTH_CLIENT_ID`,
`TS_OAUTH_SECRET`, `DEPLOY_SSH_PRIVATE_KEY`, and
`DEPLOY_SSH_KNOWN_HOSTS`. The Tailscale OAuth client creates an ephemeral
`tag:ci` node; the tailnet policy restricts that tag to TCP port 22 on the two
deployment targets.

To rotate the SSH identity, replace the public key in
`modules/ssh-deploy.nix`, deploy it before removing the old key, then replace
the environment secret. From a machine with GitHub CLI access, install the SSH
values without printing the private key:

```console
gh secret set --repo jmalexan/nix --env production \
  DEPLOY_SSH_PRIVATE_KEY < .local/github-actions-deploy
ssh-keyscan -t ed25519 nasa htpc | \
  gh secret set --repo jmalexan/nix --env production DEPLOY_SSH_KNOWN_HOSTS
```

## Adding a container image

Put an annotation directly above the image assignment:

```nix
# renovate: datasource=docker depName=ghcr.io/example/application
image = "ghcr.io/example/application:1.2.3";
```

Use an exact upstream release tag when one is practical. Use a rolling channel
only when that is intentional, and retain Renovate's digest pin. Couple images
that must release together with a package rule in `renovate.json5`.
