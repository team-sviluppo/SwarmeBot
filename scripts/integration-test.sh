#!/usr/bin/env bash
# Start a harness on a throwaway data dir and run the integration tests
# against it. Your ~/.swarmebot is never touched.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
REPO="${SWARMEBOT_REPO:-$ROOT/../SwarmeBot}"
PORT="${SWARMEBOT_IT_PORT:-38799}"
DATA="$(mktemp -d -t swarmebot-it)"
LOG="$DATA/server.log"
OMB_DATA_DIR="$DATA" OMB_PORT="$PORT" OMB_WEBHOOK_PORT=$((PORT + 1)) OMB_SKILLS_DIR="$REPO/skills" \
  node --experimental-strip-types --no-warnings "$REPO/server/index.ts" >"$LOG" 2>&1 &
PID=$!
trap 'kill $PID 2>/dev/null; wait $PID 2>/dev/null; rm -rf "$DATA"' EXIT
for _ in $(seq 1 60); do
  curl -sf "http://127.0.0.1:$PORT/api/health" >/dev/null && break
  sleep 0.5
done
curl -sf "http://127.0.0.1:$PORT/api/health" >/dev/null || { echo "harness did not start"; cat "$LOG"; exit 1; }
cd "$ROOT"
SWARMEBOT_IT_PORT=$PORT swift test --filter HarnessIntegrationTests
