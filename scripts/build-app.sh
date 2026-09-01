#!/usr/bin/env bash
# Builds Port Wizard and assembles a runnable .app bundle (menu-bar agent).
# Usage: ./scripts/build-app.sh [debug|release]
set -euo pipefail

CONFIG="${1:-release}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="PortWizard"
BUILD_DIR="$ROOT/.build/$CONFIG"
APP_BUNDLE="$ROOT/.build/$APP_NAME.app"

echo "==> Building ($CONFIG)…"
swift build -c "$CONFIG" --package-path "$ROOT"

echo "==> Assembling $APP_NAME.app…"
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"

cp "$BUILD_DIR/$APP_NAME" "$APP_BUNDLE/Contents/MacOS/$APP_NAME"
cp "$ROOT/Resources/Info.plist" "$APP_BUNDLE/Contents/Info.plist"
# The bundle is not shippable without its icon, and a missing one used to be
# silent — a successful build producing a blank-page icon in Finder.
ICON="$ROOT/Resources/AppIcon.icns"
if [ ! -f "$ICON" ]; then
  echo "error: missing $ICON" >&2
  echo "       regenerate it with ./scripts/make-appicon.sh" >&2
  exit 1
fi
cp "$ICON" "$APP_BUNDLE/Contents/Resources/AppIcon.icns"

# Ad-hoc sign so the app can run locally without Gatekeeper complaints.
codesign --force --deep --sign - "$APP_BUNDLE" 2>/dev/null || true

echo "==> Done: $APP_BUNDLE"
echo "    Run with: open \"$APP_BUNDLE\"   (look for the icon in the menu bar)"
