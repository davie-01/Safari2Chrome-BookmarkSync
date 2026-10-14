#!/bin/bash
# Builds the release artefacts into dist/: the app in a .dmg, and the extension as a .zip.
# Usage: scripts/package.sh [--no-dmg]
#   CODESIGN_ID="Apple Development: ..."  passed through to build-app.sh
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DIST="$ROOT/dist"
VERSION="$(sed -n 's/.*"version": "\([^"]*\)".*/\1/p' "$ROOT/extension/manifest.json" | head -1)"

rm -rf "$DIST"
mkdir -p "$DIST"

echo "==> building BookmarkSync.app $VERSION"
"$ROOT/scripts/build-app.sh" --no-install >/dev/null
APP="$ROOT/build/BookmarkSync.app"
[ -d "$APP" ] || { echo "build failed: no $APP"; exit 1; }

echo "==> extension zip"
(cd "$ROOT/extension" && zip -qr "$DIST/bookmarksync-extension-$VERSION.zip" . \
  -x "node_modules/*" "test/*" "*.map" ".DS_Store")

if [ "${1:-}" != "--no-dmg" ]; then
  echo "==> dmg"
  STAGE="$(mktemp -d)"
  cp -R "$APP" "$STAGE/"
  ln -s /Applications "$STAGE/Applications"
  hdiutil create -quiet -volname "BookmarkSync $VERSION" -srcfolder "$STAGE" \
    -ov -format UDZO "$DIST/BookmarkSync-$VERSION.dmg"
  rm -rf "$STAGE"
fi

echo "==> checksums"
(cd "$DIST" && shasum -a 256 * > SHA256SUMS.txt && cat SHA256SUMS.txt)
echo "done: $DIST"
