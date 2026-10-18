#!/usr/bin/env bash
# The Linux engines for a release — docs/plans/2026-10-16-bot-remoto.md §3.6.
#
#   scripts/linux-engines-manifest.sh <version> [--skip-build]
#
# Builds both architectures (scripts/build-linux-engine.sh) unless asked not
# to, stages them as release assets, and writes Resources/linux-engines.json:
# the URL each asset will have on the GitHub release v<version>, its size and
# its SHA-256. bundle-app.sh puts that file in the app; the app downloads an
# engine only when a server needs one and uses it only if the digest matches.
#
# Output: build/linux/release/swarme-harness-linux-{aarch64,x86_64}
# Environment: RELEASES_REPO (default team-sviluppo/SwarmeBot).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="${1:-}"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "usage: $0 <version 1.2.3> [--skip-build]" >&2; exit 2; }
RELEASES_REPO="${RELEASES_REPO:-team-sviluppo/SwarmeBot}"
[[ "${2:-}" == "--skip-build" ]] || "$ROOT/scripts/build-linux-engine.sh" aarch64 x86_64

STAGE="$ROOT/build/linux/release"
rm -rf "$STAGE" && mkdir -p "$STAGE"
entries=()
for arch in aarch64 x86_64; do
  built="$ROOT/build/linux/swarme-harness-$arch"
  [[ -f "$built" ]] || { echo "missing $built: build it first" >&2; exit 3; }
  asset="swarme-harness-linux-$arch"
  cp "$built" "$STAGE/$asset"
  sha="$(shasum -a 256 "$STAGE/$asset" | cut -d' ' -f1)"
  size="$(stat -f %z "$STAGE/$asset")"
  url="https://github.com/${RELEASES_REPO}/releases/download/v${VERSION}/${asset}"
  entries+=("\"$arch\": {\"url\": \"$url\", \"sha256\": \"$sha\", \"size\": $size}")
done
{
  echo "{"
  echo "  \"version\": \"$VERSION\","
  echo "  \"engines\": {"
  echo "    ${entries[0]},"
  echo "    ${entries[1]}"
  echo "  }"
  echo "}"
} > "$ROOT/Resources/linux-engines.json"
python3 -I -c "import json,sys; json.load(open(sys.argv[1]))" "$ROOT/Resources/linux-engines.json"
echo "→ Resources/linux-engines.json for v$VERSION"
ls -lh "$STAGE"
