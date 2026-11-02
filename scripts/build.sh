#!/usr/bin/env bash
# Build with private plugins from ../SwarmeBotPlugins when available.
# Usage: scripts/build.sh [--no-private-plugins] [swift build options...]
# Override the checkout with SWARMEBOT_PRIVATE_PLUGINS_DIR.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PREPARE=()
BUILD=()
for arg in "$@"; do
  case "$arg" in
    --no-private-plugins) PREPARE+=("$arg") ;;
    *) BUILD+=("$arg") ;;
  esac
done
python3 -I "$ROOT/scripts/prepare-private-plugins.py" ${PREPARE[@]+"${PREPARE[@]}"}
cd "$ROOT"
exec swift build ${BUILD[@]+"${BUILD[@]}"}
