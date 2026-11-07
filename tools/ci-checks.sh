#!/usr/bin/env bash
set -euo pipefail

# Build the Linux repository checks.
checks=(lint microapps microapps-web notifications git-broker approval-ssh-gate agent-network agent-guest)
targets=()
for check in "${checks[@]}"; do
  targets+=(".#checks.x86_64-linux.$check")
done
nix build --no-link "${targets[@]}"
