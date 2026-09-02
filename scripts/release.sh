#!/usr/bin/env bash
# Builds, signs, notarizes, and packages Port Wizard into a distributable DMG.
#
# For a fully shippable build you need an Apple Developer account:
#   DEVELOPER_ID="Developer ID Application: Your Name (TEAMID)"   # signing identity
#   AC_KEYCHAIN_PROFILE="notary"                                  # notarytool profile
#     (create once: xcrun notarytool store-credentials notary \
#        --apple-id you@example.com --team-id TEAMID --password <app-specific-pw>)
#
# Without those, it still produces an ad-hoc-signed, un-notarized DMG for local
# sharing (recipients must right-click → Open the first time).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="PortWizard"
APP="$ROOT/.build/$APP_NAME.app"
DMG="$ROOT/.build/$APP_NAME.dmg"

# The .icns is committed, so a release does not regenerate it — the mark is
# only redrawn on purpose, via ./scripts/make-appicon.sh.
echo "==> Building release app bundle…"
"$ROOT/scripts/build-app.sh" release

if [ -n "${DEVELOPER_ID:-}" ]; then
  echo "==> Signing with Developer ID + hardened runtime…"
  codesign --force --deep --options runtime --timestamp \
    --sign "$DEVELOPER_ID" "$APP"
  codesign --verify --strict --verbose=2 "$APP"
else
  echo "==> No DEVELOPER_ID set — leaving the ad-hoc signature (local use only)."
fi

# --no-build so the signature above survives into the DMG.
echo "==> Building DMG…"
"$ROOT/scripts/build-dmg.sh" --no-build

if [ -n "${DEVELOPER_ID:-}" ] && [ -n "${AC_KEYCHAIN_PROFILE:-}" ]; then
  echo "==> Notarizing (this can take a few minutes)…"
  xcrun notarytool submit "$DMG" --keychain-profile "$AC_KEYCHAIN_PROFILE" --wait
  echo "==> Stapling…"
  xcrun stapler staple "$DMG"
  xcrun stapler staple "$APP"
  echo "==> Notarized & stapled ✓"
else
  echo "==> Skipping notarization (need DEVELOPER_ID + AC_KEYCHAIN_PROFILE)."
fi

echo "==> Done: $DMG"
