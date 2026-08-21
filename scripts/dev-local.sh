#!/usr/bin/env bash
# Start harness server, then Vite, then the Electron desktop app.
# Usage (from repo root): ./scripts/dev-local.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

SERVER_PORT="${OMB_PORT:-${OGB_PORT:-8799}}"
UI_PORT="${OMB_UI_PORT:-5199}"
PIDS=()

cleanup() {
  for pid in "${PIDS[@]:-}"; do
    kill "$pid" 2>/dev/null || true
  done
}
trap cleanup EXIT INT TERM

wait_port() {
  local host="$1" port="$2" name="$3"
  echo "Waiting for $name on $host:$port ..."
  for _ in $(seq 1 60); do
    if curl -sf "http://$host:$port" >/dev/null 2>&1 \
      || curl -sf "http://$host:$port/api/health" >/dev/null 2>&1; then
      echo "$name is up."
      return 0
    fi
    # Vite/Electron may not have a health route; TCP is enough.
    if command -v nc >/dev/null 2>&1 && nc -z "$host" "$port" 2>/dev/null; then
      echo "$name is up."
      return 0
    fi
    sleep 0.5
  done
  echo "Timed out waiting for $name on $host:$port" >&2
  exit 1
}

if [[ ! -x "$ROOT/node_modules/.bin/vitest" || ! -x "$ROOT/node_modules/.bin/vite" || ! -x "$ROOT/node_modules/.bin/electron" ]]; then
  echo "Installing dependencies..."
  pnpm install
fi

if [[ "${SKIP_TESTS:-}" != "1" ]]; then
  echo "Running focused tests..."
  "$ROOT/node_modules/.bin/vitest" run \
    src/lib/engine-rail.test.ts \
    server/drivers/local-inject.test.ts \
    server/drivers/local-inject-matrix.test.ts
fi

echo "Starting harness server..."
pnpm dev:server &
PIDS+=($!)
wait_port 127.0.0.1 "$SERVER_PORT" "server"

echo "Starting Vite app..."
pnpm dev &
PIDS+=($!)
wait_port 127.0.0.1 "$UI_PORT" "app"

echo "Starting Electron desktop..."
pnpm dev:desktop
