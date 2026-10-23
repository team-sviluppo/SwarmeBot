#!/usr/bin/env bash
# Build the remote engine for Linux servers — docs/plans/2026-10-16-bot-remoto.md §3.6.
#
#   scripts/build-linux-engine.sh [aarch64|x86_64 ...]   (default: both)
#
# In Docker, on the Swift Ubuntu 24.04 image: glibc 2.39, so the binary runs
# on Ubuntu 24.04 and 26.04. The Swift runtime is linked in
# (--static-swift-stdlib); the server needs only libsqlite3-0 and libcurl4t64,
# which the setup installs. x86_64 runs under emulation on Apple silicon:
# slow (about 11 minutes with QEMU), but the same toolchain. Docker Desktop
# needs an amd64 handler: turn on Rosetta in its settings, or register QEMU
# in its VM (until Docker restarts):
#   docker run --privileged --rm tonistiigi/binfmt --install amd64
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
      # /src is read-only. Swift 6.4 opens Package.resolved read-write to refresh
      # pins (EROFS, errno 30, reported as an I/O error while reading). Build from
      # a writable copy on the cache volume; scratch stays beside it.
      rm -rf /build/src
      mkdir -p /build/src
      tar -C /src --exclude .build --exclude .git --exclude .swiftpm --exclude build --exclude release -cf - . | tar -C /build/src -xf -
      swift build --package-path /build/src --scratch-path /build/spm --product swarme-harness -c release --static-swift-stdlib
      cp /build/spm/release/swarme-harness /out/swarme-harness-'"$arch"'
      strip /out/swarme-harness-'"$arch"'
    '
  (cd "$OUT" && shasum -a 256 "swarme-harness-$arch" | cut -d" " -f1 > "swarme-harness-$arch.sha256")
  echo "   $(du -h "$OUT/swarme-harness-$arch" | cut -f1)  $(cat "$OUT/swarme-harness-$arch.sha256")"
done
