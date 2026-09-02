#!/usr/bin/env bash
# Builds Port Wizard and packages it into a distributable installer .dmg.
# Usage: ./scripts/build-dmg.sh [debug|release]
set -euo pipefail

CONFIG="${1:-release}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="PortWizard"
APP_BUNDLE="$ROOT/.build/$APP_NAME.app"
DMG_PATH="$ROOT/.build/$APP_NAME.dmg"
STAGING_DIR="$ROOT/.build/dmg-staging"

"$ROOT/scripts/build-app.sh" "$CONFIG"

echo "==> Staging DMG contents…"
rm -rf "$STAGING_DIR" "$DMG_PATH"
mkdir -p "$STAGING_DIR"
cp -R "$APP_BUNDLE" "$STAGING_DIR/$APP_NAME.app"
ln -s /Applications "$STAGING_DIR/Applications"

echo "==> Creating ${DMG_PATH}..."
hdiutil create -volname "Port Wizard" -srcfolder "$STAGING_DIR" -ov -format UDZO "$DMG_PATH"

rm -rf "$STAGING_DIR"

echo "==> Done: $DMG_PATH"
