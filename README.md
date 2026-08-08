# Nix systems

This flake manages three machines and one NixOS container:

| Name | Platform | Channel | Role |
| --- | --- | --- | --- |
| `nasa` | NixOS x86_64 | 26.05 | NAS, storage, and self-hosted services |
| `home` | NixOS container on `nasa` | 26.05 | General home automation shell environment |
| `htpc` | NixOS x86_64 | unstable | Plasma Bigscreen media client |
| `Book` | nix-darwin aarch64 | unstable | Personal workstation |

Shared system policy lives in `modules/`, shared values in `lib/vars.nix`, and
host ownership starts in `hosts/<host>/default.nix`. NAS services are explicitly
listed by `hosts/nasa/services/default.nix`; adding a file does not silently
enable it.

## Routine commands

```console
nix develop
nix fmt
nix flake check --no-build --all-systems
nix build .#checks.x86_64-linux.lint
nix run .#package-diff -- nasa
```

Deploy NixOS with `sudo nixos-rebuild switch --flake .#nasa` (or `.#htpc`).
Deploy the Mac with `darwin-rebuild switch --flake .#Book`. The `update-now`
command on a host pulls and activates the configured GitHub branch.

## Updates

Renovate owns dependency discovery. Install the hosted Renovate GitHub App for
this repository; it will create a Dependency Dashboard issue and propose flake,
GitHub Actions, and annotated container-image updates. The configuration is in
`renovate.json5`.

Container images use two policies:

- Versioned releases retain their version tag and receive tag/digest update PRs.
- Intentional rolling channels such as `stable` and `latest` retain the channel
  name, but Renovate pins and refreshes the digest in reviewable PRs.

Nothing auto-merges. Major container upgrades require approval from the
Dependency Dashboard. See [docs/updates.md](docs/updates.md) for the review and
deployment workflow.

## Operations

- [Architecture and ownership](docs/architecture.md)
- [Updates and Renovate](docs/updates.md)
- [NAS backups and restore](docs/nasa-recovery.md)
- [HTPC remote and playback](docs/htpc-remote.md)

Secrets are encrypted with agenix. `secrets.nix` is the recipient inventory;
encrypted payloads remain safe to commit, but decrypted material must never be
added to the repository.
