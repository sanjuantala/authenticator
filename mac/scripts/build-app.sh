#!/bin/bash
# Builds Totem.app (menu bar app + browser bridge) and installs it to /Applications.
# Usage:  ./scripts/build-app.sh            → build + install to /Applications
#         ./scripts/build-app.sh --no-install
set -euo pipefail
cd "$(dirname "$0")/.."

if [ "${SKIP_TESTS:-0}" != "1" ]; then
  echo "› Checking the core (vault format must match the extension)…"
  swift run TotemCoreCheck Tests/TotemCoreTests/Fixtures/js-vault.json
fi

echo "› Building release…"
swift build -c release
BIN="$(swift build -c release --show-bin-path)"

APP="build/Totem.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/Totem" "$APP/Contents/MacOS/Totem"
cp "$BIN/TotemBridge" "$APP/Contents/MacOS/TotemBridge"

VERSION="$(cat ../VERSION 2>/dev/null || echo 1.0.0)"
BUILD="$(date +%Y%m%d%H%M)"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>Totem</string>
  <key>CFBundleDisplayName</key><string>Totem</string>
  <key>CFBundleIdentifier</key><string>app.totem.mac</string>
  <key>CFBundleExecutable</key><string>Totem</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$BUILD</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHumanReadableCopyright</key><string>Personal build</string>
</dict></plist>
PLIST

echo "› Making the icon…"
ICONSET="build/AppIcon.iconset"; rm -rf "$ICONSET"; mkdir -p "$ICONSET"
for s in 16 32 128 256 512; do
  sips -z $s $s AppIcon-1024.png --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
  d=$((s*2)); sips -z $d $d AppIcon-1024.png --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"

echo "› Signing (ad-hoc, for your own Mac)…"
codesign --force --sign - "$APP/Contents/MacOS/TotemBridge"
codesign --force --sign - --identifier app.totem.mac "$APP"

if [ "${1:-}" != "--no-install" ]; then
  echo "› Installing to /Applications…"
  pkill -x Totem 2>/dev/null || true
  for _ in 1 2 3 4 5 6 7 8 9 10; do pgrep -x Totem >/dev/null || break; sleep 0.5; done   # let the old copy quit
  rm -rf /Applications/Totem.app
  cp -R "$APP" /Applications/
  rm -rf ./build                     # leave only /Applications/Totem.app (no duplicates in Spotlight)
  # macOS needs a moment to register the new copy before it can open it (otherwise: error -600)
  for attempt in 1 2 3 4 5; do
    sleep 1
    open /Applications/Totem.app 2>/dev/null && break
    [ "$attempt" = 5 ] && echo "  (Open Totem from Applications yourself; it's installed.)"
  done
  echo "✓ Totem is in your menu bar. Then: Settings → Sync & Backup → Connect browsers."
else
  echo "✓ Built $APP"
fi
