#!/usr/bin/env bash
# Build, sign, notarize, and staple macOS DMGs so they can be installed on
# other company Macs without Gatekeeper blocking them. Internal distribution
# only — no App Store, no public GitHub feed, no in-app auto-update.
#
# This is the local fallback described in docs/releasing.md. It must run on a
# Mac, with YOUR Apple Developer Program credentials — a fork cannot reuse the
# original author's Developer ID certificate or notarization key.
#
# One-time setup:
#   ./scripts/package-mac-dmg.sh --setup
#
# Then, from the repo root:
#   ./scripts/package-mac-dmg.sh
#
# Optional env (also loaded from .env.mac-release.local, which is gitignored):
#   MAC_SIGN_IDENTITY   Developer ID Application: Name (TEAMID)
#   CSC_LINK            path to a .p12 (alternative to a keychain identity)
#   CSC_KEY_PASSWORD    password for that .p12
#   APPLE_ID / APPLE_APP_SPECIFIC_PASSWORD / APPLE_TEAM_ID
#                       notarization via Apple ID (no API key needed)
#   NOTARY_PROFILE      notarytool keychain profile (default: AC_PASSWORD)
#                       used only when the Apple ID trio is not set
#   MAC_ARCHES          arm64, x64, or arm64,x64 (default: both)
#
# Flags:
#   --setup           print Apple account steps; store notarytool credentials
#   --skip-notarize   build + sign only (other Macs will still Gatekeeper-block)
#   --notarize-only   skip the build; notarize/staple whatever is in release/
#   --help
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

NOTARY_PROFILE="${NOTARY_PROFILE:-AC_PASSWORD}"
MAC_ARCHES="${MAC_ARCHES:-arm64}"
ENV_FILE="$ROOT/.env.mac-release.local"
PRODUCT_NAME="SwarmeBot"

SKIP_NOTARIZE=0
NOTARIZE_ONLY=0

usage() {
  sed -n '2,28p' "$0" | sed 's/^# \?//'
}

load_env() {
  if [[ -f "$ENV_FILE" ]]; then
    echo "Loading $ENV_FILE"
    # Parse KEY=VALUE ourselves so values with spaces or parentheses
    # (e.g. Developer ID Application: Name (TEAMID)) do not need to be
    # valid bash. `source` would treat "(" as syntax.
    local line key value
    while IFS= read -r line || [[ -n "$line" ]]; do
      [[ -z "${line//[[:space:]]/}" || "$line" =~ ^[[:space:]]*# ]] && continue
      if [[ "$line" =~ ^([A-Za-z_][A-Za-z0-9_]*)=(.*)$ ]]; then
        key="${BASH_REMATCH[1]}"
        value="${BASH_REMATCH[2]}"
        if [[ "$value" =~ ^\"(.*)\"$ ]]; then
          value="${BASH_REMATCH[1]}"
        elif [[ "$value" =~ ^\'(.*)\'$ ]]; then
          value="${BASH_REMATCH[1]}"
        fi
        export "${key}=${value}"
      fi
    done < "$ENV_FILE"
    NOTARY_PROFILE="${NOTARY_PROFILE:-AC_PASSWORD}"
    MAC_ARCHES="${MAC_ARCHES:-arm64,x64}"
  fi
}

die() {
  echo "error: $*" >&2
  exit 1
}

require_macos() {
  [[ "$(uname -s)" == "Darwin" ]] || die "this script must run on macOS"
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "missing command: $1"
}

list_developer_id_identities() {
  security find-identity -v -p codesigning 2>/dev/null \
    | grep -E 'Developer ID Application:' \
    | grep -v 'CSSMERR' \
    || true
}

detect_sign_identity() {
  if [[ -n "${CSC_LINK:-}" ]]; then
    echo "Signing from CSC_LINK=$CSC_LINK"
    [[ -f "$CSC_LINK" ]] || die "CSC_LINK does not exist: $CSC_LINK"
    [[ -n "${CSC_KEY_PASSWORD:-}" ]] || die "CSC_KEY_PASSWORD is required when CSC_LINK is set"
    return 0
  fi

  if [[ -z "${MAC_SIGN_IDENTITY:-}" ]]; then
    local identities identity_count
    identities="$(list_developer_id_identities)"
    identity_count="$(printf '%s\n' "$identities" | grep -c 'Developer ID Application:' || true)"
    if [[ "$identity_count" -eq 1 ]]; then
      MAC_SIGN_IDENTITY="$(printf '%s\n' "$identities" | sed -E 's/.*"([^"]+)".*/\1/')"
      echo "Auto-detected signing identity: $MAC_SIGN_IDENTITY"
    elif [[ "$identity_count" -gt 1 ]]; then
      echo "$identities" >&2
      die "multiple Developer ID Application identities found — set MAC_SIGN_IDENTITY in $ENV_FILE"
    else
      die "no Developer ID Application certificate in the keychain. Run: $0 --setup"
    fi
  fi

  # electron-builder prepends "Developer ID Application:" itself and
  # refuses CSC_NAME that already includes it.
  CSC_NAME="${MAC_SIGN_IDENTITY#Developer ID Application: }"
  export CSC_NAME
  echo "Signing identity: Developer ID Application: $CSC_NAME"
}

print_setup() {
  cat <<'EOF'
macOS DMG setup (one-time, your Apple Developer account)

A signed+notarized DMG is required to install on other Macs. Ad-hoc / unsigned
builds only open on the machine that built them (Gatekeeper: "Apple cannot
check it for malicious software" / "app is damaged").

This fork cannot use the original author's certificate
(Developer ID Application: Milind Soni (993D98NH4J)). Use yours.

Desktop signing and notarization must use the SAME team that owns the
Developer ID Application certificate (APPLE_TEAM_ID). That is a different
certificate from Apple Distribution used for iOS/TestFlight.

1. Apple Developer Program
   https://developer.apple.com/programs/
   Enrolment is required for Developer ID + notarization (~99 USD/year).

2. Developer ID Application certificate (NOT Apple Development, NOT
   Apple Distribution — those are for Xcode/dev and App Store/TestFlight).

   Easiest path:
     Xcode → Settings → Accounts → your team → Manage Certificates
     → + → Developer ID Application

   Or: https://developer.apple.com/account/resources/certificates/list
     Certificates → + → Developer ID Application → CSR from Keychain Access
     → download the .cer → double-click to install in login keychain.

   Confirm:
     security find-identity -v -p codesigning | grep "Developer ID Application"

3. Notarization credentials — Apple ID + app-specific password + team ID
   is enough (create the password at appleid.apple.com → App-Specific
   Passwords). Put them in .env.mac-release.local (gitignored):

     APPLE_ID=you@example.com
     APPLE_APP_SPECIFIC_PASSWORD=xxxx-xxxx-xxxx-xxxx
     APPLE_TEAM_ID=XXXXXXXXXX

   Or store them once in the login keychain:

     xcrun notarytool store-credentials AC_PASSWORD \
       --apple-id "$APPLE_ID" \
       --team-id "$APPLE_TEAM_ID" \
       --password "$APPLE_APP_SPECIFIC_PASSWORD"

   An App Store Connect API key (.p8) also works, but is not required.

4. Optional: pin the identity so electron-builder never picks an
   "Apple Development" cert by mistake. Add to .env.mac-release.local:

     MAC_SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)"

   Or export a .p12 from Keychain Access and set:

     CSC_LINK=/absolute/path/to/DeveloperID.p12
     CSC_KEY_PASSWORD=the-export-password

5. Bundle ID
   Desktop appId is still com.swarmebot.app. Developer ID notarization does
   not require registering that ID. Change it only if you want this fork to
   be a distinct app (separate Application Support folder, TCC prompts, and
   no clash with an installed upstream SwarmeBot).

6. Distribution is internal. Hand the DMG to colleagues (Drive, Slack,
   MDM). There is no in-app auto-update and nothing is uploaded to GitHub.

Then:
   ./scripts/package-mac-dmg.sh
EOF
}

run_setup() {
  require_macos
  print_setup
  echo
  echo "Current Developer ID Application identities:"
  local identities
  identities="$(list_developer_id_identities)"
  if [[ -z "$identities" ]]; then
    echo "  (none found — create the certificate in step 2 before building)"
  else
    printf '%s\n' "$identities"
  fi
  echo
  if has_apple_id_auth; then
    echo "APPLE_ID trio is set — notarytool will use it directly. No keychain profile needed."
  elif [[ -t 0 ]]; then
    read -r -p "Store notarytool credentials into profile '$NOTARY_PROFILE' now? [y/N] " answer
    if [[ "$answer" == [yY] ]]; then
      echo "notarytool will prompt for Apple ID / key. Profile name: $NOTARY_PROFILE"
      xcrun notarytool store-credentials "$NOTARY_PROFILE"
      echo "Stored. Test with: xcrun notarytool history --keychain-profile $NOTARY_PROFILE"
    fi
  else
    echo "Non-interactive shell: skip credential prompt. Re-run --setup in a terminal,"
    echo "or set APPLE_ID, APPLE_APP_SPECIFIC_PASSWORD, and APPLE_TEAM_ID."
  fi
}

has_apple_id_auth() {
  [[ -n "${APPLE_ID:-}" && -n "${APPLE_APP_SPECIFIC_PASSWORD:-}" && -n "${APPLE_TEAM_ID:-}" ]]
}

require_notary_auth() {
  if has_apple_id_auth; then
    echo "Notary auth: Apple ID $APPLE_ID (team $APPLE_TEAM_ID)"
    return 0
  fi
  xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1 \
    || die "set APPLE_ID + APPLE_APP_SPECIFIC_PASSWORD + APPLE_TEAM_ID, or run: $0 --setup"
}

app_version() {
  node -p "require('./package.json').version"
}

arch_args() {
  local arch
  local -a args=()
  IFS=',' read -r -a archs <<<"$MAC_ARCHES"
  for arch in "${archs[@]}"; do
    arch="$(echo "$arch" | tr -d '[:space:]')"
    case "$arch" in
      arm64|x64) args+=("--$arch") ;;
      *) die "unknown arch '$arch' (use arm64, x64, or arm64,x64)" ;;
    esac
  done
  printf '%s\n' "${args[@]}"
}

unpacked_apps() {
  local -a apps=()
  local app
  shopt -s nullglob
  for app in "$ROOT"/release/mac*/"$PRODUCT_NAME".app; do
    apps+=("$app")
  done
  ((${#apps[@]} > 0)) || die "no unpacked $PRODUCT_NAME.app under release/mac*"
  printf '%s\n' "${apps[@]}"
}

release_dmgs() {
  local -a files=()
  shopt -s nullglob
  files=("$ROOT"/release/"$PRODUCT_NAME"-*.dmg)
  ((${#files[@]} > 0)) || die "no $PRODUCT_NAME-*.dmg in release/"
  printf '%s\n' "${files[@]}"
}

verify_developer_id() {
  local app="$1"
  echo "Verifying $app"
  codesign --verify --deep --strict --verbose=2 "$app"
  local info
  info="$(codesign -dv --verbose=4 "$app" 2>&1 || true)"
  printf '%s\n' "$info" | grep -q 'Developer ID Application' \
    || die "$app is not signed with Developer ID Application (Gatekeeper will block other Macs)"
  if printf '%s\n' "$info" | grep -q 'Signature=adhoc'; then
    die "$app is ad-hoc signed. Set MAC_SIGN_IDENTITY / CSC_LINK and rebuild."
  fi
}

submit_notarize() {
  local file="$1"
  echo "Notarizing $(basename "$file") …"
  if has_apple_id_auth; then
    xcrun notarytool submit "$file" \
      --apple-id "$APPLE_ID" \
      --password "$APPLE_APP_SPECIFIC_PASSWORD" \
      --team-id "$APPLE_TEAM_ID" \
      --wait
  else
    xcrun notarytool submit "$file" --keychain-profile "$NOTARY_PROFILE" --wait
  fi
}

staple_path() {
  local file="$1"
  echo "Stapling $(basename "$file")"
  xcrun stapler staple "$file"
  xcrun stapler validate "$file"
}

copy_stable_names() {
  local version="$1"
  local arm="$ROOT/release/${PRODUCT_NAME}-${version}-arm64.dmg"
  local intel="$ROOT/release/${PRODUCT_NAME}-${version}-x64.dmg"
  if [[ -f "$arm" ]]; then
    cp -f "$arm" "$ROOT/release/${PRODUCT_NAME}.dmg"
    echo "Stable copy: release/${PRODUCT_NAME}.dmg"
  fi
  if [[ -f "$intel" ]]; then
    cp -f "$intel" "$ROOT/release/${PRODUCT_NAME}-intel.dmg"
    echo "Stable copy: release/${PRODUCT_NAME}-intel.dmg"
  fi
}

ensure_node() {
  require_cmd node
  try_use_node_24() {
    if [[ -s "${NVM_DIR:-$HOME/.nvm}/nvm.sh" ]]; then
      # nvm is a shell function, not a binary
      # shellcheck disable=SC1091
      . "${NVM_DIR:-$HOME/.nvm}/nvm.sh"
      nvm use 24 >/dev/null 2>&1 || nvm use 24.0 >/dev/null 2>&1 || true
    elif command -v fnm >/dev/null 2>&1; then
      eval "$(fnm env)"
      fnm use 24 >/dev/null 2>&1 || true
    fi
  }
  local major
  major="$(node -p "process.versions.node.split('.')[0]")"
  if ((major < 24)); then
    try_use_node_24
    major="$(node -p "process.versions.node.split('.')[0]")"
  fi
  if ((major >= 24)); then
    echo "Node $(node -v)"
    return 0
  fi
  if ((major >= 22)); then
    echo "warning: package.json asks for Node 24+; using $(node -v) for this local DMG build"
    return 0
  fi
  die "Node 22+ required (found $(node -v)). Install 24 with: nvm install 24"
}

build_signed() {
  ensure_node
  require_cmd pnpm
  require_cmd swiftc
  require_cmd lipo
  require_cmd codesign

  detect_sign_identity
  export CSC_IDENTITY_AUTO_DISCOVERY=true

  echo "Installing dependencies if needed…"
  pnpm install

  echo "Building signed macOS app (arches: $MAC_ARCHES)…"
  pnpm package:prepare
  pnpm build:speech
  pnpm build:cua

  local -a extra=()
  while IFS= read -r arg; do
    [[ -n "$arg" ]] && extra+=("$arg")
  done < <(arch_args)

  pnpm exec electron-builder --mac "${extra[@]}" --publish never

  local app
  while IFS= read -r app; do
    verify_developer_id "$app"
  done < <(unpacked_apps)
}

notarize_and_staple() {
  require_cmd xcrun
  require_notary_auth

  local file app
  while IFS= read -r file; do
    submit_notarize "$file"
  done < <(release_dmgs)

  while IFS= read -r file; do
    staple_path "$file"
  done < <(release_dmgs)
  while IFS= read -r app; do
    staple_path "$app"
  done < <(unpacked_apps)

  copy_stable_names "$(app_version)"
}

print_summary() {
  echo
  echo "Done. Artifacts in release/:"
  ls -lh "$ROOT"/release/"$PRODUCT_NAME"*.dmg 2>/dev/null || true
  echo
  echo "Install: open the matching DMG and drag $PRODUCT_NAME to Applications."
  echo "Apple silicon → ${PRODUCT_NAME}-<ver>-arm64.dmg (or ${PRODUCT_NAME}.dmg)"
  echo "Intel         → ${PRODUCT_NAME}-<ver>-x64.dmg   (or ${PRODUCT_NAME}-intel.dmg)"
  echo
  echo "Internal distribution: share that DMG. No store, no public GitHub feed."
}

# --- argv ---
while [[ $# -gt 0 ]]; do
  case "$1" in
    --help|-h) usage; exit 0 ;;
    --setup) load_env; run_setup; exit 0 ;;
    --skip-notarize) SKIP_NOTARIZE=1; shift ;;
    --notarize-only) NOTARIZE_ONLY=1; shift ;;
    *) die "unknown flag: $1 (try --help)" ;;
  esac
done

require_macos
load_env

if [[ "$NOTARIZE_ONLY" -eq 1 && "$SKIP_NOTARIZE" -eq 1 ]]; then
  die "use either --skip-notarize or --notarize-only, not both"
fi

if [[ "$NOTARIZE_ONLY" -eq 0 ]]; then
  build_signed
else
  local_app=""
  while IFS= read -r local_app; do
    verify_developer_id "$local_app"
  done < <(unpacked_apps)
fi

if [[ "$SKIP_NOTARIZE" -eq 1 ]]; then
  echo
  echo "Skipping notarization. This DMG will NOT install cleanly on other Macs."
  copy_stable_names "$(app_version)"
  print_summary
  exit 0
fi

notarize_and_staple
print_summary