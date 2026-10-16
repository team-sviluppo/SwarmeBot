#!/usr/bin/env bash
# Assemble SwarmeBot.app from the SwiftPM build.
#
#   scripts/bundle-app.sh [options]
#
#   --with-harness     also copy skills/ from the SwarmeBot checkout into
#                      the app. The engine itself is swarme-harness, always.
#   --arch arm64|x86_64|universal   (default universal) — a single-arch build
#                      halves the embedded node (~110 MB instead of ~220 MB)
#   --dmg              also produce build/SwarmeBot[-intel].dmg
#   --notarize         submit to Apple and staple (needs SIGN_IDENTITY and
#                      NOTARY_PROFILE, see below)
#
# Environment:
#   SIGN_IDENTITY="Developer ID Application: …"  Developer ID + Hardened Runtime
#                      (default: ad-hoc, local use only)
#   NOTARY_PROFILE=name  a `xcrun notarytool store-credentials` profile
#   SPARKLE_PUBLIC_KEY=… EdDSA public key from Sparkle's generate_keys; without
#                      it the updater stays off
#   SPARKLE_FEED_URL=…  default: the appcast on team-sviluppo/SwarmeBot
#   VERSION=0.1.0 BUILD_NUMBER=1
#   SWARMEBOT_REPO      the SwarmeBot checkout (default ../SwarmeBot)
#   NODE_MAJOR=24 / NODE_VERSION=v24.x.y
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
REPO="${SWARMEBOT_REPO:-$ROOT/../SwarmeBot}"
OUT="$ROOT/build"
WITH_HARNESS=0
ARCH=universal
DMG=0
NOTARIZE=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --with-harness) WITH_HARNESS=1 ;;
    --arch) ARCH="$2"; shift ;;
    --dmg) DMG=1 ;;
    --notarize) NOTARIZE=1 ;;
    *) echo "unknown option $1"; exit 2 ;;
  esac
  shift
done
IDENTITY="${SIGN_IDENTITY:--}"
if [[ $NOTARIZE == 1 && ( "$IDENTITY" == "-" || -z "${NOTARY_PROFILE:-}" ) ]]; then
  echo "--notarize needs SIGN_IDENTITY (Developer ID) and NOTARY_PROFILE"; exit 2
fi

case "$ARCH" in
  universal) SWIFT_ARCHS=(--arch arm64 --arch x86_64); NODE_ARCHS=(arm64 x64); SUFFIX="" ;;
  arm64) SWIFT_ARCHS=(--arch arm64); NODE_ARCHS=(arm64); SUFFIX="" ;;
  x86_64) SWIFT_ARCHS=(--arch x86_64); NODE_ARCHS=(x64); SUFFIX="-intel" ;;
  *) echo "--arch must be arm64, x86_64 or universal"; exit 2 ;;
esac
APP="$OUT/SwarmeBot.app"

cd "$ROOT"
swift build -c release "${SWIFT_ARCHS[@]}"
BIN_DIR="$(swift build -c release "${SWIFT_ARCHS[@]}" --show-bin-path)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Helpers" "$APP/Contents/Frameworks"
cp "$BIN_DIR/SwarmeBot" "$APP/Contents/MacOS/SwarmeBot"
# the phase-2 Swift engine, chosen in Settings › Motore
cp "$BIN_DIR/swarme-harness" "$APP/Contents/Helpers/swarme-harness"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString ${VERSION:-0.1.0}" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion ${BUILD_NUMBER:-1}" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Add :SUFeedURL string ${SPARKLE_FEED_URL:-https://github.com/team-sviluppo/SwarmeBot/releases/latest/download/appcast.xml}" "$APP/Contents/Info.plist"
if [[ -n "${SPARKLE_PUBLIC_KEY:-}" ]]; then
  /usr/libexec/PlistBuddy -c "Add :SUPublicEDKey string $SPARKLE_PUBLIC_KEY" "$APP/Contents/Info.plist"
fi

# Sparkle ships as an XCFramework; SwiftPM leaves the framework next to the
# binary, the app looks for it in Contents/Frameworks (rpath in Package.swift).
SPARKLE="$(find "$BIN_DIR" "$ROOT/.build/artifacts" -maxdepth 6 -name Sparkle.framework -type d 2>/dev/null | head -1)"
[[ -n "$SPARKLE" ]] || { echo "Sparkle.framework not found"; exit 1; }
cp -R "$SPARKLE" "$APP/Contents/Frameworks/"

# the very icon the Electron app ships (SwarmeBot/build/icon.icns)
cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"

# SwiftPM resources (provider icons); read through Bundle.resources, which
# looks in Contents/Resources — without it the app traps on the first logo
[[ -d "$BIN_DIR/SwarmeBot_SwarmeBot.bundle" ]] || { echo "SwarmeBot_SwarmeBot.bundle not found in $BIN_DIR"; exit 1; }
cp -R "$BIN_DIR/SwarmeBot_SwarmeBot.bundle" "$APP/Contents/Resources/"

if [[ $WITH_HARNESS == 1 ]]; then
  [[ -d "$REPO/skills" ]] || { echo "skills not found at $REPO (set SWARMEBOT_REPO)"; exit 1; }
  cp -R "$REPO/skills" "$APP/Contents/Resources/skills"
  echo "→ embedded skills from $REPO"
fi

# Sign inside-out: helpers and frameworks first, the app last.
OPTS=(--force --timestamp=none)
[[ "$IDENTITY" != "-" ]] && OPTS=(--force --options runtime --timestamp)
codesign "${OPTS[@]}" -s "$IDENTITY" "$APP/Contents/Helpers/swarme-harness"
SPK="$APP/Contents/Frameworks/Sparkle.framework/Versions/B"
for xpc in "$SPK"/XPCServices/*.xpc; do
  if [[ -e "$xpc" ]]; then codesign "${OPTS[@]}" -s "$IDENTITY" "$xpc"; fi
done
for helper in Autoupdate Updater.app; do
  if [[ -e "$SPK/$helper" ]]; then codesign "${OPTS[@]}" -s "$IDENTITY" "$SPK/$helper"; fi
done
codesign "${OPTS[@]}" -s "$IDENTITY" "$APP/Contents/Frameworks/Sparkle.framework"
codesign "${OPTS[@]}" -s "$IDENTITY" "$APP"
codesign --verify --deep --strict "$APP"
echo "✓ $APP"

ARTIFACT="$APP"
if [[ $DMG == 1 ]]; then
  DMG_PATH="$OUT/SwarmeBot$SUFFIX.dmg"
  rm -f "$DMG_PATH"
  STAGE="$OUT/dmg-stage"; rm -rf "$STAGE"; mkdir -p "$STAGE"
  cp -R "$APP" "$STAGE/"
  ln -s /Applications "$STAGE/Applications"
  # `hdiutil create -srcfolder` is deprecated and fails with "Resource busy"
  # on recent macOS; `diskutil image create from` is its replacement
  if diskutil image create from --help >/dev/null 2>&1; then
    diskutil image create from --format UDZO --volumeName SwarmeBot "$STAGE" "$DMG_PATH" >/dev/null
  else
    hdiutil create -volname SwarmeBot -srcfolder "$STAGE" -ov -format UDZO "$DMG_PATH" >/dev/null
  fi
  rm -rf "$STAGE"
  if [[ "$IDENTITY" != "-" ]]; then codesign --force --timestamp -s "$IDENTITY" "$DMG_PATH"; fi
  ARTIFACT="$DMG_PATH"
  echo "✓ $DMG_PATH"
fi

if [[ $NOTARIZE == 1 ]]; then
  SUBMIT="$ARTIFACT"
  if [[ "$ARTIFACT" == "$APP" ]]; then
    SUBMIT="$OUT/SwarmeBot-notarize.zip"
    ditto -c -k --keepParent "$APP" "$SUBMIT"
  fi
  echo "→ notarizing $(basename "$SUBMIT")"
  xcrun notarytool submit "$SUBMIT" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$ARTIFACT"
  if [[ "$ARTIFACT" != "$APP" ]]; then xcrun stapler staple "$APP" || true; fi
  echo "✓ notarized and stapled"
fi
