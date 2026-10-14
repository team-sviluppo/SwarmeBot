#!/usr/bin/env bash
# Every parity scenario: Local Endpoint (base, advanced, team files/avatars/cards), Claude, each ACP
# harness with its own default model and — for the ones that write their
# CLI's config — with a local model. Stops at the first diff.
set -euo pipefail
cd "$(dirname "$0")"
run() { echo "== $*"; env "$@" ./compare.sh; }
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
