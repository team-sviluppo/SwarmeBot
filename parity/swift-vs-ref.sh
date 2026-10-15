#!/usr/bin/env bash
# The parity scenarios on two builds of the Swift engine: a reference
# checkout (default: a `main` worktree in ../sb-main) and this one. Stands
# in for compare.sh while the Node engine is not on disk: a change that
# must not alter turns (connectors off, docs/plans/2026-10-15-connettori-mcp.md
# §4.3) must leave every trace byte for byte the same.
#
#   git worktree add ../sb-main main
#   TMPDIR=/tmp/swA/ parity/swift-vs-ref.sh
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
REF="${REF_DIR:-$ROOT/../sb-main}"
OUT="${TMPDIR:-/tmp}/swarme-ref"
mkdir -p "$OUT"
(cd "$REF" && swift build --product swarme-harness >/dev/null) || { echo "reference build failed ($REF)"; exit 2; }
(cd "$ROOT" && swift build --product swarme-harness >/dev/null) || exit 2
A="$(cd "$REF" && swift build --product swarme-harness --show-bin-path)/swarme-harness"
B="$(cd "$ROOT" && swift build --product swarme-harness --show-bin-path)/swarme-harness"
fail=0
run() {
  # one retry: a scenario's socket timeout is occasionally just slow
  for attempt in 1 2; do
    env "$@" python3 -I "$ROOT/parity/run_scenario.py" swift "$ROOT" "$A" > "$OUT/ref.json" 2>"$OUT/ref.err" &&
      env "$@" python3 -I "$ROOT/parity/run_scenario.py" swift "$ROOT" "$B" > "$OUT/new.json" 2>"$OUT/new.err" && break
    [ "$attempt" = 2 ] && { echo "FAILED $*"; tail -3 "$OUT/ref.err" "$OUT/new.err"; fail=1; return; }
  done
  if diff -u "$OUT/ref.json" "$OUT/new.json" > "$OUT/diff.txt"; then
    echo "OK   $* ($(python3 -c "import json;print(len(json.load(open('$OUT/ref.json'))['frames']))") frames)"
  else
    echo "DIFF $*"; head -40 "$OUT/diff.txt"; fail=1
  fi
}
run SCENARIO=base
run SCENARIO=advanced
run SCENARIO=team
run DRIVER=claude
run DRIVER=claude SCENARIO=rooms
run DRIVER=claude SCENARIO=automations
run DRIVER=claude SCENARIO=computer
run DRIVER=grok SCENARIO=base
run DRIVER=grok SCENARIO=advanced
run DRIVER=codex
run DRIVER=pi
run DRIVER=agy
run DRIVER=dsh
for driver in grokAgent geminiAgent kimiAgent droidAgent cursorAgent opencodeGo qwenAgent hermesAgent; do
  run DRIVER=acp:$driver
done
for driver in hermesAgent qwenAgent kimiAgent droidAgent opencodeGo grokAgent; do
  run DRIVER=acp:$driver ACP_MODEL=local_endpoint::fake/echo-1
done
exit $fail
