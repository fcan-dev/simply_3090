#!/usr/bin/env bash
# Start the Qwen3.8-27B llama.cpp server ON THIS MACHINE (single 24 GB card).
#
# What it does, in order:
#   0. GPU power cap — card-aware:
#        3090 Ti (450 W default) -> cap at 350 W (measured energy knee; see README)
#        3090    (350 W default) -> nothing to underclock; 350 W IS the card default
#      Override: POWER_LIMIT=<watts>  (0 = leave the limit untouched)
#   1. VRAM preflight — detects a desktop session (gdm) holding ~530 MiB that
#      would starve the KV alloc, and offers to stop it
#      (FREE_DESKTOP=ask|1|0; default: ask)
#   2. docker compose up (compose/docker-compose.yml)
#   3. wait for http://localhost:8091/health (TIMEOUT seconds), bail out early
#      on a crash-looping container, then report ctx + VRAM
#
# Usage:
#   ./scripts/start.sh
#   MODEL_DIR=/path/to/models ./scripts/start.sh
#   FREE_DESKTOP=1 ./scripts/start.sh
#   POWER_LIMIT=0 ./scripts/start.sh      # skip the power cap
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd -- "$SCRIPT_DIR/.." && pwd)"

COMPOSE_FILE="$PROJECT_DIR/compose/docker-compose.yml"
CONTAINER="llama-cpp-qwen38-27b-single-q4kxl"
PORT=${PORT:-8091}
SERVED_MODEL="qwen3.8-27b-q4kxl"
TIMEOUT=${TIMEOUT:-600}              # seconds to wait for model load + KV alloc
NEED_MIB=23860                       # what the model needs resident (measured 23,804-23,910)
FREE_DESKTOP=${FREE_DESKTOP:-ask}    # ask | 1 (auto-free) | 0 (never touch it)
POWER_LIMIT=${POWER_LIMIT:-auto}     # auto | <watts> | 0 (skip)

# ---- 0. GPU power limit (card-aware) --------------------------------------
# 350 W is the measured energy knee on the 3090 Ti (card default 450 W).
# On the non-Ti 3090, 350 W IS the card default, so there is nothing to
# underclock — detect that and leave the limit alone.
GPU_LINE=$(nvidia-smi --query-gpu=name,power.default_limit,power.limit --format=csv,noheader,nounits)
GPU_NAME=${GPU_LINE%%,*}
REST=${GPU_LINE#*, }
DEF_LIMIT=${REST%%,*}
CUR_LIMIT=${REST##*, }

TARGET=""
if [[ "$POWER_LIMIT" == "auto" ]]; then
  TARGET=350
elif [[ "$POWER_LIMIT" != "0" ]]; then
  TARGET=$POWER_LIMIT
fi

if [[ -n "$TARGET" ]]; then
  if (( DEF_LIMIT <= TARGET )); then
    echo "==> Power cap: $GPU_NAME defaults to ${DEF_LIMIT} W (<= ${TARGET} W target) — nothing to underclock, leaving the limit alone."
  else
    echo "==> Power cap: $GPU_NAME defaults to ${DEF_LIMIT} W -> capping at ${TARGET} W (current limit: ${CUR_LIMIT} W) ..."
    sudo nvidia-smi -pl "$TARGET" >/dev/null
    nvidia-smi --query-gpu=power.limit,power.draw --format=csv,noheader | sed 's/^/    /'
  fi
fi

echo "==> Starting LLM server ($SERVED_MODEL on port $PORT) ..."

# ---- 1. already running? ----------------------------------------------------
if docker ps --filter name="$CONTAINER" --format '{{.Status}}' | grep -q healthy; then
  echo "Already running and healthy (port $PORT). Nothing to do."
  docker ps --filter name="$CONTAINER" --format '{{.Names}} | {{.Image}} | {{.Status}}'
  exit 0
fi

# ---- 2. VRAM preflight ------------------------------------------------------
STATE=$(nvidia-smi --query-gpu=memory.used,memory.total --format=csv,noheader,nounits)
USED=${STATE%%,*}; TOTAL=${STATE##*, }
FREE=$(( TOTAL - USED ))
echo "==> GPU: ${USED} MiB used / ${TOTAL} MiB total  ->  ${FREE} MiB free (need ~${NEED_MIB})"

DESKTOP=$(pgrep -a -f 'gnome-shell|Xorg|gnome-remote-desktop' 2>/dev/null | head -5 || true)

if [[ "$FREE" -lt "$NEED_MIB" && -n "$DESKTOP" ]]; then
  echo "==> WARNING: not enough free VRAM and a desktop session is holding the card:"
  echo "$DESKTOP" | sed 's/^/      /'
  echo "    The desktop is worth ~530 MiB; the model needs ~${NEED_MIB} MiB."
  DO_FREE=0
  if [[ "$FREE_DESKTOP" == "1" ]]; then
    DO_FREE=1
  elif [[ "$FREE_DESKTOP" == "ask" ]]; then
    read -r -p "    Free it now (stop gdm)? [y/N] " ans || true
    [[ "${ans:-}" =~ ^[Yy]$ ]] && DO_FREE=1
  fi
  if [[ "$DO_FREE" == "1" ]]; then
    sudo systemctl set-default multi-user.target >/dev/null 2>&1
    sudo systemctl stop gdm 2>/dev/null || true
    sleep 8
    STATE=$(nvidia-smi --query-gpu=memory.used,memory.total --format=csv,noheader,nounits)
    USED=${STATE%%,*}; FREE=$(( TOTAL - USED ))
    echo "    freed -> ${FREE} MiB free now (default target set to multi-user so it stays off after reboot)"
  else
    echo "    !! continuing anyway — the model load will likely OOM (that is the known failure)"
  fi
fi

# ---- 3. bring it up ----------------------------------------------------------
docker compose -f "$COMPOSE_FILE" up -d >/dev/null
echo "==> compose up issued; waiting up to ${TIMEOUT}s for http://localhost:$PORT/health ..."

for _ in $(seq 1 $((TIMEOUT / 5))); do
  if curl -sf "http://localhost:$PORT/health" >/dev/null 2>&1; then
    CTX=$(curl -s "http://localhost:$PORT/props" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("default_generation_settings",{}).get("n_ctx"))' 2>/dev/null || echo "?")
    echo "==> UP: http://localhost:$PORT  (model: $SERVED_MODEL, ctx: $CTX)"
    docker ps --filter name="$CONTAINER" --format '{{.Names}} | {{.Image}} | {{.Status}}'
    nvidia-smi --query-gpu=memory.used,memory.total --format=csv,noheader
    exit 0
  fi
  # bail out early if the container is crash-looping
  if docker ps -a --filter name="$CONTAINER" --format '{{.Status}}' | grep -qi restarting; then
    echo "==> Container is in a restart loop (likely OOM). Last 30 log lines:" >&2
    docker logs --tail 30 "$CONTAINER" >&2 || true
    exit 1
  fi
  sleep 5
done

echo "==> Timed out waiting for health. Last 30 log lines:" >&2
docker logs --tail 30 "$CONTAINER" >&2 || true
exit 1
