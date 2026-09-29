#!/usr/bin/env bash
# Stop the Qwen3.8-27B llama.cpp server ON THIS MACHINE and report GPU state.
#
# Usage:
#   ./scripts/stop.sh                  # compose down + state report
#   ./scripts/stop.sh --free-desktop   # also stop gdm to reclaim ~530 MiB of VRAM
#   ./scripts/stop.sh --restore-power  # remove the 350 W cap (back to card default)
#
# NOTE: if you installed the reboot-persistent unit (install-power-limit.sh),
# `--restore-power` is undone on the next boot — uninstall the unit too if you
# want the cap gone for good.
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd -- "$SCRIPT_DIR/.." && pwd)"

COMPOSE_FILE="$PROJECT_DIR/compose/docker-compose.yml"
CONTAINER="llama-cpp-qwen38-27b-single-q4kxl"

echo "==> Stopping LLM server ..."
docker compose -f "$COMPOSE_FILE" down --remove-orphans

echo "==> Container state:"
docker ps -a --filter name="$CONTAINER" --format '{{.Names}} | {{.Status}}' || true

echo "==> GPU state:"
nvidia-smi --query-gpu=name,memory.used,memory.total --format=csv
echo "==> GPU processes still resident:"
nvidia-smi --query-compute-apps=pid,process_name,used_memory --format=csv,noheader || echo "    (none)"

if [[ "${1:-}" == "--free-desktop" ]]; then
  echo "==> Stopping gdm to free desktop VRAM (also sets the default boot target to multi-user) ..."
  sudo systemctl set-default multi-user.target >/dev/null 2>&1
  sudo systemctl stop gdm 2>/dev/null || true
  sleep 6
  nvidia-smi --query-gpu=memory.used,memory.total --format=csv,noheader
fi

if [[ "${1:-}" == "--restore-power" ]]; then
  DEF=$(nvidia-smi --query-gpu=power.default_limit --format=csv,noheader,nounits)
  echo "==> Restoring GPU power limit to card default (${DEF} W) ..."
  sudo nvidia-smi -pl "$DEF" >/dev/null
  nvidia-smi --query-gpu=power.limit,power.draw --format=csv,noheader
fi
