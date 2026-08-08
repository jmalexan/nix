# Updates and Renovate

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

## Deployment bootstrap

The production job is disabled for ordinary pushes until the repository
variable `AUTO_DEPLOY_ENABLED` is set to `true`. Keep the host auto-upgrade
timers enabled during bootstrap, then remove their imports after the first
successful workflow deployment.

1. Let the current timer deploy the configuration containing the `deploy` user
   and Tailscale client to both NixOS hosts.
2. On `htpc`, run `sudo tailscale up` once and approve the node if required.
3. Create a Tailscale OAuth client permitted to create ephemeral `tag:ci`
   nodes. Restrict that tag to TCP port 22 on `nasa` and `htpc` in the tailnet
   policy.
4. Add `TS_OAUTH_CLIENT_ID`, `TS_OAUTH_SECRET`,
   `DEPLOY_SSH_PRIVATE_KEY`, and `DEPLOY_SSH_KNOWN_HOSTS` to the GitHub
   `production` environment. The matching local private key is generated at
   `.local/github-actions-deploy` and is excluded from Git.
5. Run the `Check` workflow manually and confirm both deployment jobs succeed.
6. Set the repository variable `AUTO_DEPLOY_ENABLED` to `true`.

From a machine with GitHub CLI access, the two SSH values can be installed
without printing the private key:

```console
gh secret set --repo jmalexan/nix --env production \
  DEPLOY_SSH_PRIVATE_KEY < .local/github-actions-deploy
ssh-keyscan -t ed25519 nasa htpc | \
  gh secret set --repo jmalexan/nix --env production DEPLOY_SSH_KNOWN_HOSTS
```

After the manual deployment succeeds, enable push deployments with:

```console
gh variable set --repo jmalexan/nix AUTO_DEPLOY_ENABLED --body true
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
