#!/usr/bin/env bash
# Builds Port Wizard and packages it into a distributable installer .dmg.
# Usage: ./scripts/build-dmg.sh [debug|release] [--no-build]
#
# --no-build packages whatever .app is already in .build/ instead of building a
# fresh one. release.sh needs that: it signs the bundle with a Developer ID
# between the build and the DMG, and a rebuild here would ad-hoc re-sign the
# bundle and silently throw that signature away.
set -euo pipefail

CONFIG="release"
BUILD=1
for arg in "$@"; do
  case "$arg" in
    debug|release) CONFIG="$arg" ;;
    --no-build) BUILD=0 ;;
    *) echo "usage: $0 [debug|release] [--no-build]" >&2; exit 2 ;;
  esac
done

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="PortWizard"
APP_BUNDLE="$ROOT/.build/$APP_NAME.app"
DMG_PATH="$ROOT/.build/$APP_NAME.dmg"
STAGING_DIR="$ROOT/.build/dmg-staging"

if [ "$BUILD" -eq 1 ]; then
  "$ROOT/scripts/build-app.sh" "$CONFIG"
elif [ ! -d "$APP_BUNDLE" ]; then
  echo "error: --no-build given but $APP_BUNDLE does not exist" >&2
  exit 1
fi

if ! command -v create-dmg >/dev/null; then
  echo "error: create-dmg is not installed; run: brew install create-dmg" >&2
  exit 1
fi

echo "==> Staging DMG contents…"
rm -rf "$STAGING_DIR" "$DMG_PATH"
mkdir -p "$STAGING_DIR"
cp -R "$APP_BUNDLE" "$STAGING_DIR/$APP_NAME.app"

# The icon positions match the arrow in the background; if they change, update
# scripts/make-dmg-background.swift too and re-run it.
echo "==> Creating ${DMG_PATH}..."
create-dmg \
  --volname "Port Wizard" \
  --volicon "$ROOT/Resources/AppIcon.icns" \
  --background "$ROOT/Resources/dmg-background.tiff" \
  --window-size 660 400 \
  --icon-size 128 \
  --icon "$APP_NAME.app" 180 170 \
  --hide-extension "$APP_NAME.app" \
  --app-drop-link 480 170 \
  "$DMG_PATH" "$STAGING_DIR"

rm -rf "$STAGING_DIR"

echo "==> Done: $DMG_PATH"
