#!/usr/bin/env bash
# Build, sign, notarize and staple the SwarmeBot DMGs for internal
# distribution — the native app's version of SwarmeBot/scripts/package-mac-dmg.sh,
# with the same Developer ID and notarization credentials.
#
#   scripts/release-mac.sh [--version 0.3.0] [--arch arm64|x64|arm64,x64] [--skip-notarize]
#
# Credentials, read from .env.mac-release.local in this repo or, failing
# that, in the Electron checkout (../SwarmeBot/.env.mac-release.local):
#
#   MAC_SIGN_IDENTITY="Developer ID Application: Hextra Srl (3UYNX3FBA3)"
#   APPLE_ID / APPLE_APP_SPECIFIC_PASSWORD / APPLE_TEAM_ID   notarization
#   NOTARY_PROFILE      a `xcrun notarytool store-credentials` profile, used
#                       when the Apple ID trio is not set (default AC_PASSWORD)
#
# Other environment: VERSION, BUILD_NUMBER (default: the git commit count),
# MAC_ARCHES (default arm64,x64), SWARMEBOT_REPO (default ../SwarmeBot).
#
# Output: release/SwarmeBot-<version>-arm64.dmg and -x64.dmg, plus the stable
# names release/SwarmeBot.dmg (Apple silicon) and release/SwarmeBot-intel.dmg.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
REPO="${SWARMEBOT_REPO:-$ROOT/../SwarmeBot}"
OUT="$ROOT/release"
SKIP_NOTARIZE=0

die() { echo "error: $*" >&2; exit 1; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --version) VERSION="$2"; shift ;;
    --arch) MAC_ARCHES="$2"; shift ;;
    --skip-notarize) SKIP_NOTARIZE=1 ;;
    --help|-h) sed -n '2,22p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "unknown option $1 (try --help)" ;;
  esac
  shift
done

[[ "$(uname -s)" == "Darwin" ]] || die "this script must run on macOS"

# KEY=VALUE parsed by hand, like package-mac-dmg.sh: an identity such as
# "Developer ID Application: Name (TEAMID)" is not valid bash to `source`.
load_env() {
  local file="$1" line key value
  echo "→ credentials from $file"
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ -z "${line//[[:space:]]/}" || "$line" =~ ^[[:space:]]*# ]] && continue
    if [[ "$line" =~ ^([A-Za-z_][A-Za-z0-9_]*)=(.*)$ ]]; then
      key="${BASH_REMATCH[1]}"; value="${BASH_REMATCH[2]}"
      if [[ "$value" =~ ^\"(.*)\"$ ]]; then value="${BASH_REMATCH[1]}"
      elif [[ "$value" =~ ^\'(.*)\'$ ]]; then value="${BASH_REMATCH[1]}"; fi
      # the command line and the shell win over the file
      [[ -z "${!key:-}" ]] && export "$key=$value"
    fi
  done < "$file"
}
if [[ -f "$ROOT/.env.mac-release.local" ]]; then load_env "$ROOT/.env.mac-release.local"
elif [[ -f "$REPO/.env.mac-release.local" ]]; then load_env "$REPO/.env.mac-release.local"
fi

# --- signing identity ---
if [[ -z "${MAC_SIGN_IDENTITY:-}" ]]; then
  identities="$(security find-identity -v -p codesigning | grep -E 'Developer ID Application:' | sed -E 's/.*"([^"]+)".*/\1/' | sort -u)"
  [[ "$(printf '%s\n' "$identities" | grep -c .)" == 1 ]] \
    || die "set MAC_SIGN_IDENTITY in .env.mac-release.local (found: ${identities:-none})"
  MAC_SIGN_IDENTITY="$identities"
fi
[[ "$MAC_SIGN_IDENTITY" == "Developer ID Application:"* ]] || MAC_SIGN_IDENTITY="Developer ID Application: $MAC_SIGN_IDENTITY"
security find-identity -v -p codesigning | grep -qF "\"$MAC_SIGN_IDENTITY\"" \
  || die "\"$MAC_SIGN_IDENTITY\" is not in the keychain"
echo "→ signing as $MAC_SIGN_IDENTITY"

# --- notarization credentials ---
NOTARY_PROFILE="${NOTARY_PROFILE:-AC_PASSWORD}"
notary_auth() {
  if [[ -n "${APPLE_ID:-}" && -n "${APPLE_APP_SPECIFIC_PASSWORD:-}" && -n "${APPLE_TEAM_ID:-}" ]]; then
    printf '%s\n' --apple-id "$APPLE_ID" --password "$APPLE_APP_SPECIFIC_PASSWORD" --team-id "$APPLE_TEAM_ID"
  else
    printf '%s\n' --keychain-profile "$NOTARY_PROFILE"
  fi
}
NOTARY_ARGS=()
if [[ $SKIP_NOTARIZE == 0 ]]; then
  while IFS= read -r arg; do NOTARY_ARGS+=("$arg"); done < <(notary_auth)
  xcrun notarytool history "${NOTARY_ARGS[@]}" >/dev/null 2>&1 \
    || die "notarization credentials rejected: set APPLE_ID, APPLE_APP_SPECIFIC_PASSWORD and APPLE_TEAM_ID, or store profile $NOTARY_PROFILE"
fi

# --- version ---
PLIST="$ROOT/Resources/Info.plist"
VERSION="${VERSION:-$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$PLIST")}"
BUILD_NUMBER="${BUILD_NUMBER:-$(git -C "$ROOT" rev-list --count HEAD 2>/dev/null || echo 1)}"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "VERSION must look like 1.2.3 (got $VERSION)"
echo "→ version $VERSION ($BUILD_NUMBER)"

mkdir -p "$OUT"
IFS=',' read -r -a ARCHES <<<"${MAC_ARCHES:-arm64,x64}"
BUILT=()
for arch in "${ARCHES[@]}"; do
  arch="$(echo "$arch" | tr -d '[:space:]')"
  case "$arch" in
    arm64) swift_arch=arm64; made="$ROOT/build/SwarmeBot.dmg" ;;
    x64|x86_64) arch=x64; swift_arch=x86_64; made="$ROOT/build/SwarmeBot-intel.dmg" ;;
    *) die "unknown arch '$arch' (use arm64, x64 or arm64,x64)" ;;
  esac
  echo
  echo "=== $arch ==="
  SIGN_IDENTITY="$MAC_SIGN_IDENTITY" VERSION="$VERSION" BUILD_NUMBER="$BUILD_NUMBER" \
    "$ROOT/scripts/bundle-app.sh" --arch "$swift_arch" --dmg

  # bundle-app.sh signs with the Hardened Runtime; refuse anything else
  info="$(codesign -dv --verbose=4 "$ROOT/build/SwarmeBot.app" 2>&1)"
  grep -q "Authority=Developer ID Application" <<<"$info" || die "the app is not signed with Developer ID"
  grep -q "flags=.*runtime" <<<"$info" || die "the app is not signed with the Hardened Runtime"

  dmg="$OUT/SwarmeBot-$VERSION-$arch.dmg"
  mv -f "$made" "$dmg"
  if [[ $SKIP_NOTARIZE == 0 ]]; then
    echo "→ notarizing $(basename "$dmg") (a few minutes)…"
    result="$(xcrun notarytool submit "$dmg" "${NOTARY_ARGS[@]}" --wait 2>&1)" || true
    echo "$result"
    if ! grep -q "status: Accepted" <<<"$result"; then
      id="$(sed -nE 's/^ *id: ([0-9a-f-]+).*/\1/p' <<<"$result" | head -1)"
      [[ -n "$id" ]] && xcrun notarytool log "$id" "${NOTARY_ARGS[@]}" || true
      die "notarization of $(basename "$dmg") failed"
    fi
    xcrun stapler staple "$dmg"
    xcrun stapler validate "$dmg"
    spctl -a -t open --context context:primary-signature -v "$dmg"
  fi
  BUILT+=("$dmg")
  case "$arch" in
    arm64) cp -f "$dmg" "$OUT/SwarmeBot.dmg" ;;
    x64) cp -f "$dmg" "$OUT/SwarmeBot-intel.dmg" ;;
  esac
done

echo
echo "Done:"
ls -lh "${BUILT[@]}"
[[ $SKIP_NOTARIZE == 1 ]] && echo "Not notarized: other Macs will block these DMGs."
echo "Apple silicon → release/SwarmeBot.dmg · Intel → release/SwarmeBot-intel.dmg"
