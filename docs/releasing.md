# Releasing

One workflow builds everything: **Actions → Release → Run workflow**. It
builds macOS (arm64 + x64, signed, notarized, stapled), Windows, and Ubuntu
from a single pinned commit, verifies every artifact the way a user would
receive it, assembles a complete draft on
[swarmebot-releases](https://github.com/team-sviluppo/swarmebot-releases),
and — if you ticked **publish** — flips it live. Leave publish unticked to
review the draft notes first, then publish from the GitHub UI.

The workflow refuses to overwrite an already-published version, so the only
prerequisite per release is that `package.json`'s version is bumped on the
ref you run it against.

## Why the gates exist

Each verification step in `release.yml` maps to a real incident from the
hand-cut releases (0.1.15–0.1.25): stale build output breaking the code
signature, a bare import killing the packaged server on launch while every
check stayed green, helper paths resolving outside the app after bundling,
stapling silently invalidating every published hash, and a finished release
sitting invisible as a draft. Don't remove a gate without reading the comment
above it.

## One-time setup: four secrets

Set these in **SwarmeBot → Settings → Secrets and variables → Actions**.

### 1. `MAC_CERT_P12_BASE64` + `MAC_CERT_PASSWORD`

The Developer ID Application certificate, exported from the Mac that
currently signs releases:

```sh
# Keychain Access → My Certificates → "Developer ID Application: Milind Soni
# (993D98NH4J)" → right-click → Export… → .p12 with a strong password, then:
base64 -i DeveloperID.p12 | pbcopy   # → MAC_CERT_P12_BASE64
# the export password             → MAC_CERT_PASSWORD
```

### 2. `APPLE_API_KEY_P8_BASE64` + `APPLE_API_KEY_ID` + `APPLE_API_ISSUER_ID`

An App Store Connect API key for notarization (better than an app-specific
password for CI — revocable, scoped, no 2FA dance):

1. [App Store Connect → Users and Access → Integrations → App Store Connect API](https://appstoreconnect.apple.com/access/integrations/api)
2. Generate a **Team Key** with the **Developer** role
3. Download the `.p8` (one chance only), note the Key ID and Issuer ID

```sh
base64 -i AuthKey_XXXXXXXX.p8 | pbcopy   # → APPLE_API_KEY_P8_BASE64
```

### 3. `RELEASES_PAT`

A fine-grained personal access token that lets the workflow write to the
separate releases repo: **GitHub → Settings → Developer settings →
Fine-grained tokens** → repository access: only `swarmebot-releases` →
permissions: **Contents: Read and write**. Set a long expiry and a calendar
reminder.

### Local fallback

The hand-cut path still works when Actions is down, when this is a fork
without the upstream GitHub secrets, or when a release needs surgery.

On a Mac, with **your** Developer ID Application certificate and a
`notarytool` keychain profile (the original author's identity cannot be
reused):

```sh
./scripts/package-mac-dmg.sh --setup   # one-time: cert + notarization profile
./scripts/package-mac-dmg.sh           # build, sign, notarize, staple
```

That script is the local equivalent of the CI gates: `pnpm package:mac`,
`codesign --verify --deep --strict`, `xcrun notarytool submit …
--keychain-profile AC_PASSWORD`, staple, re-zip, regenerate blockmaps, and
`node scripts/regenerate-mac-feed.mjs`. Upload the `release/` artifacts,
publish, and always verify the published bytes against the published feed
by downloading them back.
