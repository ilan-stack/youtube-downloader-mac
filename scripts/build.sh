#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="YouTube Downloader"
APP_DIR="$ROOT/$APP_NAME.app"
EXEC_NAME="YTDownloader"

echo ">> swift build (release)"
cd "$ROOT"
swift build -c release

BIN_PATH="$ROOT/.build/release/$EXEC_NAME"
if [ ! -f "$BIN_PATH" ]; then
  echo "Binary not found at $BIN_PATH" >&2
  exit 1
fi

echo ">> assembling $APP_NAME.app"
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS"
mkdir -p "$APP_DIR/Contents/Resources"

# Executable
cp "$BIN_PATH" "$APP_DIR/Contents/MacOS/$EXEC_NAME"
chmod +x "$APP_DIR/Contents/MacOS/$EXEC_NAME"

# Bundled binaries
for bin in yt-dlp ffmpeg ffprobe; do
  if [ -f "$ROOT/Resources/$bin" ]; then
    cp "$ROOT/Resources/$bin" "$APP_DIR/Contents/Resources/$bin"
    chmod +x "$APP_DIR/Contents/Resources/$bin"
    echo "   bundled: $bin"
  else
    echo "   WARNING: $bin not found at $ROOT/Resources/$bin (skipping)"
  fi
done

# Icon
if [ -f "$ROOT/Resources/AppIcon.icns" ]; then
  cp "$ROOT/Resources/AppIcon.icns" "$APP_DIR/Contents/Resources/AppIcon.icns"
fi

# Info.plist
cat > "$APP_DIR/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>YouTube Downloader</string>
    <key>CFBundleDisplayName</key><string>YouTube Downloader</string>
    <key>CFBundleIdentifier</key><string>com.ilans.ytdownloader</string>
    <key>CFBundleVersion</key><string>1.0</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>CFBundleExecutable</key><string>YTDownloader</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSAppleEventsUsageDescription</key><string>Needed for system file dialogs.</string>
</dict>
</plist>
EOF

# Ad-hoc sign
codesign --force --deep --sign - "$APP_DIR" 2>/dev/null || true

echo ">> built: $APP_DIR"
APP_SIZE=$(du -sh "$APP_DIR" | awk '{print $1}')
echo "   size:   $APP_SIZE"

# Optional: create .dmg if first arg is "dmg"
if [ "${1:-}" = "dmg" ]; then
  echo ">> creating .dmg"
  DMG_PATH="$ROOT/$APP_NAME.dmg"
  STAGE="$ROOT/.dmg-stage"
  rm -rf "$STAGE" "$DMG_PATH"
  mkdir -p "$STAGE"
  cp -R "$APP_DIR" "$STAGE/"
  ln -s /Applications "$STAGE/Applications"

  hdiutil create -volname "$APP_NAME" -srcfolder "$STAGE" -ov -format UDZO "$DMG_PATH" >/dev/null
  rm -rf "$STAGE"
  echo ">> built: $DMG_PATH ($(du -sh "$DMG_PATH" | awk '{print $1}'))"
fi

echo ""
echo "Run with: open \"$APP_DIR\""
[ "${1:-}" = "dmg" ] && echo "Install:  open \"$ROOT/$APP_NAME.dmg\""
