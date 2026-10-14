#!/usr/bin/env bash
# Run the same scenario on the Node and the Swift engine and diff the traces.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
REPO="${SWARMEBOT_REPO:-$ROOT/../SwarmeBot}"
OUT="${TMPDIR:-/tmp}/swarme-parity"
mkdir -p "$OUT"
(cd "$ROOT" && swift build --product swarme-harness >/dev/null)
BIN="$(cd "$ROOT" && swift build --product swarme-harness --show-bin-path)/swarme-harness"
python3 -I "$ROOT/parity/run_scenario.py" node "$REPO" "$BIN" > "$OUT/node.json"
python3 -I "$ROOT/parity/run_scenario.py" swift "$REPO" "$BIN" > "$OUT/swift.json"
if diff -u "$OUT/node.json" "$OUT/swift.json" > "$OUT/diff.txt"; then
  echo "PARITY OK ($(python3 -c "import json;print(len(json.load(open('$OUT/node.json'))['frames']))" ) frames)"
else
  echo "PARITY DIFF — $OUT/diff.txt"; head -80 "$OUT/diff.txt"; exit 1
fi
