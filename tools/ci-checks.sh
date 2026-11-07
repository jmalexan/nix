#!/usr/bin/env bash
set -euo pipefail

# Run the ZFS restore VM separately to bound concurrent VM resource use.
nix build --no-link --print-build-logs .#checks.x86_64-linux.robots-backup

# Keep required PR checks and the independent main cache warmer identical.
checks=(lint microapps microapps-web notifications git-broker approval-ssh-gate agent-network agent-guest)
targets=()
for check in "${checks[@]}"; do
  targets+=(".#checks.x86_64-linux.$check")
done
nix build --no-link "${targets[@]}"
