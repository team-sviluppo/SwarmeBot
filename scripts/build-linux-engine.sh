#!/usr/bin/env bash
# Build the remote engine for Linux servers — docs/plans/2026-10-16-bot-remoto.md §3.6.
#
#   scripts/build-linux-engine.sh [aarch64|x86_64 ...]   (default: both)
#
# In Docker, on the Swift Ubuntu 24.04 image: glibc 2.39, so the binary runs
# on Ubuntu 24.04 and 26.04. The Swift runtime is linked in
# (--static-swift-stdlib); the server needs only libsqlite3-0 and libcurl4t64,
# which the setup installs. x86_64 runs under emulation on Apple silicon:
# slow (tens of minutes), but the same toolchain.
#
# Output: build/linux/swarme-harness-<arch> and a .sha256 next to each.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
IMAGE="${SWIFT_LINUX_IMAGE:-swift:6.4-noble}"
OUT="$ROOT/build/linux"
mkdir -p "$OUT"
arches=("$@")
[ ${#arches[@]} -eq 0 ] && arches=(aarch64 x86_64)
for arch in "${arches[@]}"; do
  case "$arch" in
    aarch64) platform=linux/arm64 ;;
    x86_64) platform=linux/amd64 ;;
    *) echo "unknown arch $arch (aarch64|x86_64)" >&2; exit 2 ;;
  esac
  echo "== $arch ($platform)"
  # a named volume per arch keeps the build cache between runs, out of the checkout
  docker run --rm --platform "$platform" \
    -v "$ROOT":/src:ro -v "sbr-linux-build-$arch":/build -v "$OUT":/out \
    "$IMAGE" bash -euo pipefail -c '
      apt-get update -qq >/dev/null
      apt-get install -y -qq libsqlite3-dev >/dev/null
      swift build --package-path /src --scratch-path /build --product swarme-harness -c release --static-swift-stdlib
      cp /build/release/swarme-harness /out/swarme-harness-'"$arch"'
      strip /out/swarme-harness-'"$arch"'
    '
  (cd "$OUT" && shasum -a 256 "swarme-harness-$arch" | cut -d" " -f1 > "swarme-harness-$arch.sha256")
  echo "   $(du -h "$OUT/swarme-harness-$arch" | cut -f1)  $(cat "$OUT/swarme-harness-$arch.sha256")"
done
