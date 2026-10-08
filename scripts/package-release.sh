#!/usr/bin/env bash
# Build the Release app and wrap it in a DMG.
# Used by .github/workflows/release.yml and runnable locally.
#
# Usage: scripts/package-release.sh [output-dir]   (default: dist)
set -euo pipefail

cd "$(dirname "$0")/.."

OUT="${1:-dist}"
CONFIG=Release

rm -rf "$OUT"

xcodebuild build \
  -project macterm.xcodeproj \
  -scheme macterm \
  -configuration "$CONFIG" \
  -destination 'platform=macOS' \
  -derivedDataPath "$OUT/DerivedData"

APP="$(find "$OUT/DerivedData/Build/Products/$CONFIG" -maxdepth 1 -name '*.app' | head -1)"
if [ -z "$APP" ]; then
  echo "no .app produced in $OUT/DerivedData/Build/Products/$CONFIG" >&2
  exit 1
fi

STAGE="$OUT/dmg"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"

DMG="$OUT/MacTerm-Release.dmg"
hdiutil create -volname MacTerm -srcfolder "$STAGE" -ov -format UDZO "$DMG"

echo "built $DMG"