#!/usr/bin/env bash
# Move old TrueNAS container configs to /Data/smb/Backups/TrueNAS/.
#
# This covers:
#   - Services already migrated to NixOS (homeassistant, immich, jellyfin,
#     qbittorrent, nginx, ddns)
#   - Services that were TrueNAS containers but not yet re-added to NixOS
#     (calibre, factorio, minecraft, romm, radicale, znc, etc.)
#
# Nothing is deleted — everything moves to Backups/TrueNAS/ for review.
# Run as root or a user with write access to /Data/smb/Backups/.

set -euo pipefail

SRC="/Data/smb/Containers"
DEST="/Data/smb/Backups/TrueNAS"

if [ ! -d "$SRC" ]; then
  echo "Nothing to do: $SRC does not exist."
  exit 0
fi

echo "=== TrueNAS cleanup ==="
echo "Moving: $SRC"
echo "    To: $DEST"
echo ""
echo "Subdirectories to be moved:"
ls -1 "$SRC"
echo ""

read -rp "Proceed? [y/N] " confirm
if [[ "${confirm,,}" != "y" ]]; then
  echo "Aborted."
  exit 0
fi

mkdir -p "$DEST"

# Move the entire Containers directory into the archive location.
mv "$SRC" "$DEST/Containers"

echo ""
echo "Done. Old container configs are now at $DEST/Containers/"
echo ""
echo "──────────────────────────────────────────────────────────────────────────"
echo "TrueNAS ZFS datasets also still present on the pool (not touched by"
echo "this script — destroy manually once you are confident nothing is needed):"
echo ""
echo "  Data/.system       (~41 GB)  TrueNAS system state, netdata, samba4, logs"
echo "  Data/.ix-virt      (~689 MB) TrueNAS virtualization images"
echo "  Data/ix-applications (~13 GB) Old k3s app releases"
echo "  Data/ix-apps       (~211 GB) Newer TrueNAS app mounts"
echo "    Notable contents:"
echo "      /.ix-apps/app_mounts/open-webui/ollama  (~37 GB) — Ollama AI models"
echo "      /.ix-apps/app_mounts/factorio/factorio   (~1.2 GB) — Factorio save"
echo "      /.ix-apps/app_mounts/freshrss/           (~500 MB) — FreshRSS data"
echo "      /.ix-apps/app_mounts/romm/resources      (~7.7 GB) — RomM artwork"
echo ""
echo "To destroy a dataset (IRREVERSIBLE):"
echo "  sudo zfs destroy -r Data/.system"
echo "  sudo zfs destroy -r Data/.ix-virt"
echo "  sudo zfs destroy -r Data/ix-applications"
echo "  sudo zfs destroy -r Data/ix-apps"
