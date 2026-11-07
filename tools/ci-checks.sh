#!/usr/bin/env bash
set -euo pipefail

# Light checks always run. With no selection, local and full runs include all VMs.
exec python3 - <<'PYTHON'
import json
import os

light = ["lint", "microapps", "microapps-web", "notifications", "git-broker", "backups"]
vms = ["approval-ssh-gate", "agent-network", "agent-guest", "robots-backup"]
selected = json.loads(os.environ.get("CI_VM_CHECKS") or json.dumps(vms))
if (not isinstance(selected, list)
    or any(not isinstance(name, str) or name not in vms for name in selected)
    or len(selected) != len(set(selected))):
    raise SystemExit("Invalid VM check selection")
print("VM checks: " + (", ".join(selected) or "unchanged from validated base"), flush=True)
os.execvp("nix", ["nix", "build", "--no-link"] + [
    ".#checks.x86_64-linux." + name for name in light + selected
])
PYTHON
