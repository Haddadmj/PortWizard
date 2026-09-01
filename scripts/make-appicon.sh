#!/usr/bin/env bash
# Regenerates Resources/AppIcon.icns from the SF Symbols that make up the mark.
# Usage: ./scripts/make-appicon.sh
#
# make-appicon.swift shares its geometry with the shipped menu-bar mark
# (Sources/PortWizard/SymbolDrawing.swift), so the two are compiled together
# rather than the script being interpreted on its own.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TOOL="$ROOT/.build/make-appicon"

mkdir -p "$ROOT/.build"
swiftc -O \
  "$ROOT/Sources/PortWizard/SymbolDrawing.swift" \
  "$ROOT/scripts/make-appicon.swift" \
  -o "$TOOL"

cd "$ROOT"
"$TOOL"
