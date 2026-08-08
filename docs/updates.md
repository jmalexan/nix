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
4. Merge the PR. NixOS hosts pick up the configured branch automatically;
   `Book` is deliberately activated by hand with `update-now`.
5. Verify the affected service and keep the previous generation until the
   change has settled.

Renovate updates flake inputs, GitHub Actions, and Nix container declarations
carrying a `# renovate:` annotation. It does not provide meaningful version PRs
for unversioned Homebrew formula/cask declarations; those follow Homebrew when
the Mac is upgraded separately.

## Adding a container image

Put an annotation directly above the image assignment:

```nix
# renovate: datasource=docker depName=ghcr.io/example/application
image = "ghcr.io/example/application:1.2.3";
```

Use an exact upstream release tag when one is practical. Use a rolling channel
only when that is intentional, and retain Renovate's digest pin. Couple images
that must release together with a package rule in `renovate.json5`.
