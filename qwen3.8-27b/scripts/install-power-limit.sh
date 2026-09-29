#!/usr/bin/env bash
# Install (or remove) the reboot-persistent GPU power-limit unit ON THIS MACHINE.
#
# Deploys scripts/gpu-power-limit.service to /etc/systemd/system and enables it,
# so the 350 W cap is applied on every boot — including the auto-started
# llama.cpp container, which comes up via `restart: unless-stopped` without
# start.sh ever running.
#
# The unit is card-safe by construction: on a 3090 Ti (450 W default) it
# underclocks to 350 W; on a 3090 (350 W default) `nvidia-smi -pl 350` is a
# harmless no-op.
#
# Usage:
#   ./scripts/install-power-limit.sh              # install + enable + start
#   ./scripts/install-power-limit.sh --uninstall  # disable + remove
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
UNIT_NAME="gpu-power-limit.service"

if [[ "${1:-}" == "--uninstall" ]]; then
  echo "==> Disabling and removing $UNIT_NAME ..."
  sudo systemctl disable --now "$UNIT_NAME" 2>/dev/null || true
  sudo rm -f "/etc/systemd/system/$UNIT_NAME"
  sudo systemctl daemon-reload
  echo "==> GPU power limit now:"
  nvidia-smi --query-gpu=power.limit --format=csv,noheader
  exit 0
fi

echo "==> Installing $UNIT_NAME (limit 350 W) ..."
sudo install -m 0644 "$SCRIPT_DIR/$UNIT_NAME" "/etc/systemd/system/$UNIT_NAME"
sudo systemctl daemon-reload
sudo systemctl enable --now "$UNIT_NAME"

echo "==> Unit state:"
echo "    enabled=$(systemctl is-enabled "$UNIT_NAME")   active=$(systemctl is-active "$UNIT_NAME")"
echo "==> GPU power limit / draw:"
nvidia-smi --query-gpu=power.limit,power.draw --format=csv,noheader
echo "==> Done. The limit is now applied at every boot."
