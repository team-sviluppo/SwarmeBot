#!/usr/bin/env bash
# Build, sign, notarize and staple the SwarmeBot DMGs for internal
# distribution — the native app's version of SwarmeBot/scripts/package-mac-dmg.sh,
# with the same Developer ID and notarization credentials.
#
#   scripts/release-mac.sh [--version 0.3.0] [--arch arm64|x64|arm64,x64]
#                          [--skip-notarize] [--no-publish]
#
# Credentials, read from .env.mac-release.local in this repo or, failing
# that, in the Electron checkout (../SwarmeBot/.env.mac-release.local):
#
#   MAC_SIGN_IDENTITY="Developer ID Application: Hextra Srl (3UYNX3FBA3)"
#   APPLE_ID / APPLE_APP_SPECIFIC_PASSWORD / APPLE_TEAM_ID   notarization
#   NOTARY_PROFILE      a `xcrun notarytool store-credentials` profile, used
#                       when the Apple ID trio is not set (default AC_PASSWORD)
#   SPARKLE_PUBLIC_KEY  EdDSA public key from Sparkle's generate_keys
#   SPARKLE_PRIVATE_KEY the matching private key (base64). Omit it to use the
#                       key generate_keys stored in the login keychain.
#
# Other environment: VERSION, BUILD_NUMBER (default: the git commit count),
# MAC_ARCHES (default arm64,x64), SWARMEBOT_REPO (default ../SwarmeBot),
# RELEASES_REPO (default team-sviluppo/SwarmeBot).
#
# Output: release/SwarmeBot-<version>-arm64.dmg and -x64.dmg, plus the stable
# names release/SwarmeBot.dmg (Apple silicon) and release/SwarmeBot-intel.dmg.
# Unless --no-publish, also a git tag vX.Y.Z pushed to origin, then a zip per
# arch and appcast.xml uploaded as the GitHub release for that tag.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
REPO="${SWARMEBOT_REPO:-$ROOT/../SwarmeBot}"
OUT="$ROOT/release"
RELEASES_REPO="${RELEASES_REPO:-team-sviluppo/SwarmeBot}"
SKIP_NOTARIZE=0
PUBLISH=1

die() { echo "error: $*" >&2; exit 1; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --version) VERSION="$2"; shift ;;
    --arch) MAC_ARCHES="$2"; shift ;;
    --skip-notarize) SKIP_NOTARIZE=1 ;;
    --no-publish) PUBLISH=0 ;;
    --help|-h) sed -n '2,27p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
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

if [[ $PUBLISH == 1 && -z "${SPARKLE_PUBLIC_KEY:-}" ]]; then
  die "set SPARKLE_PUBLIC_KEY (from Sparkle generate_keys) or pass --no-publish"
fi
if [[ $PUBLISH == 1 ]]; then
  command -v gh >/dev/null || die "gh is required to publish (or pass --no-publish)"
  gh auth status >/dev/null 2>&1 || die "gh is not logged in to a account that can write $RELEASES_REPO"
fi

# Sparkle's sign_update is not inside the framework SwiftPM fetches.
ensure_sign_update() {
  if command -v sign_update >/dev/null 2>&1; then SIGN_UPDATE="$(command -v sign_update)"; return; fi
  local dir="$ROOT/.build/sparkle-tools" ver="${SPARKLE_TOOLS_VERSION:-2.6.4}"
  if [[ ! -x "$dir/sign_update" ]]; then
    mkdir -p "$dir"
    echo "→ downloading Sparkle ${ver} sign_update"
    curl -fsSL -o "$dir/Sparkle.tar.xz" \
      "https://github.com/sparkle-project/Sparkle/releases/download/${ver}/Sparkle-${ver}.tar.xz"
    tar -xJf "$dir/Sparkle.tar.xz" -C "$dir" bin/sign_update
    mv -f "$dir/bin/sign_update" "$dir/sign_update"
    chmod +x "$dir/sign_update"
    rm -rf "$dir/bin" "$dir/Sparkle.tar.xz"
  fi
  SIGN_UPDATE="$dir/sign_update"
}

mkdir -p "$OUT"
IFS=',' read -r -a ARCHES <<<"${MAC_ARCHES:-arm64,x64}"
BUILT=()
ZIPS=()
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
    SPARKLE_PUBLIC_KEY="${SPARKLE_PUBLIC_KEY:-}" \
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

  # Sparkle replaces the .app from a zip. The DMG stays the first-install download.
  if [[ $PUBLISH == 1 ]]; then
    zip="$OUT/SwarmeBot-$VERSION-$arch.zip"
    rm -f "$zip"
    ditto -c -k --keepParent "$ROOT/build/SwarmeBot.app" "$zip"
    if [[ $SKIP_NOTARIZE == 0 ]]; then
      echo "→ notarizing $(basename "$zip")…"
      result="$(xcrun notarytool submit "$zip" "${NOTARY_ARGS[@]}" --wait 2>&1)" || true
      echo "$result"
      if ! grep -q "status: Accepted" <<<"$result"; then
        id="$(sed -nE 's/^ *id: ([0-9a-f-]+).*/\1/p' <<<"$result" | head -1)"
        [[ -n "$id" ]] && xcrun notarytool log "$id" "${NOTARY_ARGS[@]}" || true
        die "notarization of $(basename "$zip") failed"
      fi
    fi
    ZIPS+=("$zip")
  fi
done

if [[ $PUBLISH == 1 ]]; then
  ensure_sign_update
  keyfile=""
  if [[ -n "${SPARKLE_PRIVATE_KEY_FILE:-}" ]]; then
    keyfile="$SPARKLE_PRIVATE_KEY_FILE"
  elif [[ -n "${SPARKLE_PRIVATE_KEY:-}" ]]; then
    keyfile="$(mktemp)"
    printf '%s' "$SPARKLE_PRIVATE_KEY" > "$keyfile"
    chmod 600 "$keyfile"
  fi
  enclosures=""
  for zip in "${ZIPS[@]}"; do
    base="$(basename "$zip")"
    case "$base" in
      *-arm64.zip) sparkle_arch=arm64 ;;
      *-x64.zip) sparkle_arch=x86_64 ;;
      *) die "cannot tell the architecture of $base" ;;
    esac
    echo "→ signing $base"
    if [[ -n "$keyfile" ]]; then
      sig="$("$SIGN_UPDATE" --ed-key-file "$keyfile" "$zip")"
    else
      sig="$("$SIGN_UPDATE" "$zip")"
    fi
    length="$(stat -f %z "$zip")"
    url="https://github.com/${RELEASES_REPO}/releases/download/v${VERSION}/${base}"
    enclosures+="      <enclosure url=\"${url}\" sparkle:edSignature=\"$(sed -nE 's/.*edSignature="([^"]+)".*/\1/p' <<<"$sig")\" length=\"${length}\" type=\"application/octet-stream\" sparkle:os=\"macos\" sparkle:arch=\"${sparkle_arch}\"/>"$'\n'
  done
  [[ -n "$keyfile" && -n "${SPARKLE_PRIVATE_KEY:-}" && -z "${SPARKLE_PRIVATE_KEY_FILE:-}" ]] && rm -f "$keyfile"

  pubdate="$(LC_ALL=C date -u '+%a, %d %b %Y %H:%M:%S +0000')"
  appcast="$OUT/appcast.xml"
  cat > "$appcast" <<EOF
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>SwarmeBot</title>
    <item>
      <title>Version ${VERSION}</title>
      <pubDate>${pubdate}</pubDate>
      <sparkle:version>${BUILD_NUMBER}</sparkle:version>
      <sparkle:shortVersionString>${VERSION}</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>
${enclosures}    </item>
  </channel>
</rss>
EOF
  grep -q 'sparkle:edSignature="[^"]\+"' "$appcast" || die "sign_update did not produce an EdDSA signature"

  tag="v${VERSION}"
  # GitHub rejects the Release ("tag name can't be blank / not well-formed")
  # unless the git tag already exists. Create it on HEAD and push it first.
  sha="$(git -C "$ROOT" rev-parse HEAD)"
  echo "→ tag $tag ($sha)"
  if git -C "$ROOT" rev-parse -q --verify "refs/tags/$tag" >/dev/null; then
    have="$(git -C "$ROOT" rev-parse "refs/tags/${tag}^{}")"
    [[ "$have" == "$sha" ]] || die "tag $tag already points at ${have:0:12}, not HEAD ${sha:0:12}"
  else
    git -C "$ROOT" tag -a "$tag" -m "SwarmeBot ${VERSION}"
  fi
  remote_sha=""
  while read -r ref_sha ref_name; do
    [[ -n "$ref_sha" ]] || continue
    if [[ "$ref_name" == *"^{}" ]]; then remote_sha="$ref_sha"
    elif [[ -z "$remote_sha" ]]; then remote_sha="$ref_sha"; fi
  done < <(git -C "$ROOT" ls-remote origin "refs/tags/${tag}" "refs/tags/${tag}^{}")
  if [[ -z "$remote_sha" ]]; then
    echo "→ pushing $tag to origin"
    git -C "$ROOT" push origin "refs/tags/$tag"
  elif [[ "$remote_sha" != "$sha" ]]; then
    die "origin tag $tag points at ${remote_sha:0:12}, not HEAD ${sha:0:12}"
  fi

  echo "→ publishing $tag on $RELEASES_REPO"
  if gh release view "$tag" --repo "$RELEASES_REPO" >/dev/null 2>&1; then
    gh release upload "$tag" --repo "$RELEASES_REPO" --clobber \
      "${BUILT[@]}" "${ZIPS[@]}" "$appcast"
  else
    gh release create "$tag" --repo "$RELEASES_REPO" --target "$sha" \
      --title "SwarmeBot ${VERSION}" \
      --notes "SwarmeBot ${VERSION} (${BUILD_NUMBER}) per macOS. Apple silicon: SwarmeBot-${VERSION}-arm64.dmg. Intel: SwarmeBot-${VERSION}-x64.dmg." \
      "${BUILT[@]}" "${ZIPS[@]}" "$appcast"
  fi
fi

echo
echo "Done:"
ls -lh "${BUILT[@]}" ${ZIPS[@]+"${ZIPS[@]}"}
[[ $SKIP_NOTARIZE == 1 ]] && echo "Not notarized: other Macs will block these DMGs."
echo "Apple silicon → release/SwarmeBot.dmg · Intel → release/SwarmeBot-intel.dmg"
[[ $PUBLISH == 1 ]] && echo "Appcast → https://github.com/${RELEASES_REPO}/releases/latest/download/appcast.xml"
