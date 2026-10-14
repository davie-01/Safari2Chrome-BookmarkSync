#!/bin/bash
# 编译 bmsync，打包成 BookmarkSync.app，安装到 ~/Applications，并注册后台服务与 Chrome native host。
# 用法：scripts/build-app.sh [--no-install] [--test]
#   CODESIGN_ID="Apple Development: ..."  指定签名身份（默认自动找 Apple Development，找不到则 ad-hoc）
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
NATIVE="$ROOT/native"
BUILD="$ROOT/build"
APP_NAME="BookmarkSync.app"
DEST_DIR="$HOME/Applications"
DEST="$DEST_DIR/$APP_NAME"
DO_INSTALL=1
DO_TEST=0
for a in "$@"; do
  case "$a" in
    --no-install) DO_INSTALL=0 ;;
    --test) DO_TEST=1 ;;
  esac
done

cd "$NATIVE"
if [ "$DO_TEST" = 1 ]; then
  echo "==> swift test"
  swift test
fi
echo "==> swift build -c release"
swift build -c release
BINDIR="$(swift build -c release --show-bin-path)"
BIN="$BINDIR/bmsync"
APPBIN="$BINDIR/BookmarkSync"
VERSION="$("$BIN" version)"

echo "==> 打包 $APP_NAME ($VERSION)"
rm -rf "$BUILD/$APP_NAME"
mkdir -p "$BUILD/$APP_NAME/Contents/MacOS" "$BUILD/$APP_NAME/Contents/Resources"
cp "$BIN" "$BUILD/$APP_NAME/Contents/MacOS/bmsync"
cp "$APPBIN" "$BUILD/$APP_NAME/Contents/MacOS/BookmarkSync"
cp "$NATIVE/Resources/engine.js" "$BUILD/$APP_NAME/Contents/Resources/engine.js"
# the sync UI is shared with the browser extension
mkdir -p "$BUILD/$APP_NAME/Contents/Resources/web/ui" "$BUILD/$APP_NAME/Contents/Resources/web/icons"
cp "$ROOT/extension/ui/"* "$BUILD/$APP_NAME/Contents/Resources/web/ui/"
cp "$ROOT/extension/icons/"* "$BUILD/$APP_NAME/Contents/Resources/web/icons/" 2>/dev/null || true
if [ -d "$NATIVE/Resources/AppIcon.iconset" ]; then
  iconutil -c icns "$NATIVE/Resources/AppIcon.iconset" -o "$BUILD/$APP_NAME/Contents/Resources/AppIcon.icns"
fi
cat > "$BUILD/$APP_NAME/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>com.mars.davie-01.BookmarkSync</string>
  <key>CFBundleName</key><string>BookmarkSync</string>
  <key>CFBundleDisplayName</key><string>BookmarkSync</string>
  <key>CFBundleExecutable</key><string>BookmarkSync</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSSupportsAutomaticTermination</key><false/>
  <key>NSHumanReadableCopyright</key><string>Personal use</string>
</dict>
</plist>
PLIST

# Background agent embedded in the bundle, registered with SMAppService by `bmsync install`
mkdir -p "$BUILD/$APP_NAME/Contents/Library/LaunchAgents"
cat > "$BUILD/$APP_NAME/Contents/Library/LaunchAgents/com.mars.davie-01.BookmarkSync.sync.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>com.mars.davie-01.BookmarkSync.sync</string>
  <key>BundleProgram</key><string>Contents/MacOS/BookmarkSync</string>
  <key>ProgramArguments</key><array><string>BookmarkSync</string><string>agent</string></array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>ProcessType</key><string>Background</string>
  <key>AssociatedBundleIdentifiers</key><array><string>com.mars.davie-01.BookmarkSync</string></array>
</dict>
</plist>
PLIST

IDENTITY="${CODESIGN_ID:-}"
if [ -z "$IDENTITY" ]; then
  IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null | sed -n 's/.*"\(Apple Development[^"]*\)".*/\1/p' | head -1 || true)"
fi
# bmsync is a second binary inside Contents/MacOS (agent + native host + CLI); nested code
# has to be signed before the bundle, or launchd refuses to spawn it (OS_REASON_CODESIGNING).
if [ -n "$IDENTITY" ]; then
  echo "==> codesign: $IDENTITY"
else
  IDENTITY="-"
  echo "==> codesign: ad-hoc（注意：每次重新编译后都需要在「完全磁盘访问权限」里重新勾选）"
fi
codesign --force --sign "$IDENTITY" --identifier com.mars.davie-01.BookmarkSync.helper "$BUILD/$APP_NAME/Contents/MacOS/bmsync"
codesign --force --sign "$IDENTITY" --identifier com.mars.davie-01.BookmarkSync "$BUILD/$APP_NAME"
codesign --verify --strict --deep "$BUILD/$APP_NAME" && echo "✓ 签名校验通过"

[ "$DO_INSTALL" = 1 ] || { echo "已生成 $BUILD/$APP_NAME"; exit 0; }

echo "==> 安装到 $DEST"
mkdir -p "$DEST_DIR"
launchctl kill TERM "gui/$(id -u)/com.mars.davie-01.BookmarkSync.agent" 2>/dev/null || true
launchctl kill TERM "gui/$(id -u)/com.mars.davie-01.BookmarkSync.sync" 2>/dev/null || true
launchctl kill TERM "gui/$(id -u)/local.bookmarksync.sync" 2>/dev/null || true
rm -rf "$DEST"
cp -R "$BUILD/$APP_NAME" "$DEST"
# let LaunchServices know the bundle (name + icon for 登录项与扩展 / 完全磁盘访问权限)
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$DEST" >/dev/null 2>&1 || true
# register as the app itself (SMAppService refuses registrations attributed to Terminal)
REG=$(mktemp); open -W -n --stdout "$REG" --stderr "$REG" "$DEST" --args install; cat "$REG"; rm -f "$REG"
echo
"$DEST/Contents/MacOS/bmsync" status || true
cat <<MSG

完成。首次安装还需要两步：
  1. 系统设置 → 隐私与安全性 → 完全磁盘访问权限 → 点「+」加入 $DEST 并勾选
     （可执行：open "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles"）
     然后：launchctl kickstart -k gui/\$(id -u)/com.mars.davie-01.BookmarkSync.sync
  2. Chrome 打开 chrome://extensions → 开启「开发者模式」→「加载已解压的扩展程序」→ 选择 $ROOT/extension
MSG
