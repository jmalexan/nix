# Persistent package store in robots

Robots boots from a read-only EROFS image and overlays a writable Nix store on
its persistent root disk. The Nix database also persists. Previously, changing
the boot image could remove packages from the lower layer while the database
and locally built environments still referenced them. Nix then treated missing
files as already installed and failed instead of downloading them.

The initrd service `agent-seed-nix-store` copies the boot image's missing store
entries into the writable layer **before the overlay is mounted**. It refuses to
edit the backing directory of an already mounted overlay. Each package is copied
to a private staging directory, flushed, and atomically renamed into place. A
root-owned generation marker avoids repeating the copy on an unchanged boot.

The userspace service `agent-persist-nix-store` verifies existence before the Nix
daemon starts or guest readiness is reported. The global store stays read-only;
only this verifier's private mount namespace is writable for cache cleanup. The
robot account gains no sudo or trusted-daemon access.

This uses additional writable disk space roughly equal to the uncompressed boot
closure on the first upgraded boot. Subsequent generations reuse unchanged store
paths. Normal Nix garbage collection can reclaim obsolete, unrooted packages;
project directories, credentials, profiles and active store roots are preserved.
The saved Nix database and package files now remain together on the VM disk.

If existence verification finds stale references from an older image change,
the service runs normal garbage collection, verifies again, and fails readiness
if the inconsistency remains. It does not replace the database, delete project
files or profiles, or accept incorrect hashes. First-boot copying can take
longer, so host readiness allows up to eleven minutes.

## Preserve image symlinks

The pinned microvm image builder binds each top-level store entry into its
packing directory. A bind mount dereferences a symlink. For example, the Nix man
output should be a symlink to the manual package, and a getty entry should point
to its executable; the old image materialized their targets instead. Their file
contents remained usable but their NAR hashes no longer matched the database.

The robots image builder copies the closure with `cp -a` before packing EROFS.
This preserves the exact symlink representation, keeps the configured compression
settings, and verifies the filesystem type and label required for boot.

## Verification and recovery

`checks.x86_64-linux.agent-guest` boots two different images against one persistent
disk. The first image includes a symlinked package and creates a rooted local
reference to it. The second excludes that package entirely. The test verifies
that the old package and reference still exist, retain their hashes and symlink
type, and remain readable even though the second read-only image lacks them.
It also checks that the global store remains read-only and ordinary unprivileged
Nix writes still work.

For diagnostics inside robots:

```sh
nix-store --verify
nix-store --verify --check-contents
journalctl -b -u agent-seed-nix-store -u agent-persist-nix-store --no-pager
```

A regular `nix-store --gc` followed by `nix-store --verify` can clear stale entries
that are referenced only by obsolete build caches. Nix protects rooted packages;
uncached build outputs will be rebuilt or downloaded when needed. Repairing a
missing live package with `--repair` requires root and is not granted to robot.
A regenerated boot image is needed to correct the old image's symlink types.
Do not reset the store database or discard the VM disk as a shortcut.
