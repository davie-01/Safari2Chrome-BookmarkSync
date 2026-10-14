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

echo "==> extension zip (source install: keeps the pinned ID)"
(cd "$ROOT/extension" && zip -qr "$DIST/bookmarksync-extension-$VERSION.zip" . \
  -x "node_modules/*" "test/*" "*.map" ".DS_Store")

echo "==> extension zip (Chrome Web Store upload: no key, no dev files)"
# The store assigns the extension ID from its own key, and rejects a manifest "key"
# field, so this package drops it. Development files are left out too.
WS="$DIST/webstore"
mkdir -p "$WS"
STORE_SRC="$(mktemp -d)"
cp -R "$ROOT/extension/." "$STORE_SRC/"
# engine/ runs in the app (bundled into Resources/engine.js) and in the Node tests;
# nothing in the extension imports it, so the store package leaves it out.
rm -rf "$STORE_SRC/test" "$STORE_SRC/node_modules" "$STORE_SRC/engine" \
       "$STORE_SRC/build-engine.mjs" "$STORE_SRC/package.json" \
       "$STORE_SRC/package-lock.json" "$STORE_SRC/.DS_Store"
# guard: fail the build if the extension ever starts importing engine/
if grep -rqE "from '\\./engine/|from \"\\./engine/" "$STORE_SRC" 2>/dev/null; then
  echo "extension now imports engine/ — stop excluding it from the store package" >&2
  exit 1
fi
python3 - "$STORE_SRC/manifest.json" <<'PYEOF'
import json, re, sys
p = sys.argv[1]
s = open(p, encoding='utf-8').read()
s = re.sub(r'^[ \t]*"key"[ \t]*:.*\n', '', s, flags=re.M)
open(p, 'w', encoding='utf-8').write(s)
m = json.load(open(p, encoding='utf-8'))
assert 'key' not in m, 'key field still present'
assert len(m['description']) <= 132, 'description over 132 chars'
print('    manifest ok: %s %s' % (m['name'], m['version']))
PYEOF
(cd "$STORE_SRC" && zip -qr "$WS/bookmarksync-extension-$VERSION-webstore.zip" . -x ".DS_Store")
rm -rf "$STORE_SRC"

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
(cd "$DIST" && find . -maxdepth 1 -type f ! -name SHA256SUMS.txt -print0 \
   | sort -z | xargs -0 shasum -a 256 > SHA256SUMS.txt && cat SHA256SUMS.txt)
echo "done: $DIST"
echo "  上架用: $DIST/webstore/bookmarksync-extension-$VERSION-webstore.zip"
