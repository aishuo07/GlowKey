#!/usr/bin/env sh
set -eu

ROOT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
VERSION="${1:-dev}"
DIST_DIR="$ROOT_DIR/dist"
WORK_DIR="$DIST_DIR/GlowKey-$VERSION"
APP_DIR="$WORK_DIR/GlowKey.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"
ZIP_PATH="$DIST_DIR/GlowKey-$VERSION-macos.zip"

cd "$ROOT_DIR"

swift build -c release

rm -rf "$WORK_DIR" "$ZIP_PATH"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"

for binary in glowkey glowkey-shade glowkey-hotkeys glowkey-daemon glowkey-menubar; do
  cp "$ROOT_DIR/.build/release/$binary" "$MACOS_DIR/$binary"
  chmod 755 "$MACOS_DIR/$binary"
done

cat > "$CONTENTS_DIR/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key>
  <string>glowkey-menubar</string>
  <key>CFBundleIdentifier</key>
  <string>fyi.glowkey.app</string>
  <key>CFBundleName</key>
  <string>GlowKey</string>
  <key>CFBundleIconFile</key>
  <string>AppIcon</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>LSUIElement</key>
  <true/>
</dict>
</plist>
PLIST

if [ -f "$HOME/Applications/GlowKey.app/Contents/Resources/AppIcon.png" ]; then
  cp "$HOME/Applications/GlowKey.app/Contents/Resources/AppIcon.png" "$RESOURCES_DIR/AppIcon.png"
fi

for binary in glowkey glowkey-shade glowkey-hotkeys glowkey-daemon glowkey-menubar; do
  codesign --force --sign - "$MACOS_DIR/$binary"
done
codesign --force --sign - "$APP_DIR"

cp "$ROOT_DIR/scripts/install-cli.sh" "$WORK_DIR/install-cli.sh"
chmod 755 "$WORK_DIR/install-cli.sh"

cat > "$WORK_DIR/README.txt" <<EOF
GlowKey $VERSION

Install:
1. Move GlowKey.app to /Applications or ~/Applications.
2. Right-click GlowKey.app, choose Open, then confirm Open.
3. GlowKey installs its menu bar, background restore, shortcuts, and CLI automatically.

Homebrew:
  brew tap aishuo07/glowkey
  brew trust aishuo07/glowkey
  brew install --cask glowkey

CLI after install:
  ~/bin/glowkey status
  ~/bin/glowkey uninstall

Note:
This package is currently unsigned and not notarized. macOS Gatekeeper may require
right-click > Open for first launch.
EOF

cp "$ROOT_DIR/LICENSE" "$WORK_DIR/LICENSE"
cp "$ROOT_DIR/THIRD_PARTY_NOTICES.md" "$WORK_DIR/THIRD_PARTY_NOTICES.md"

(
  cd "$DIST_DIR"
  zip -qry "$ZIP_PATH" "GlowKey-$VERSION"
)

echo "$ZIP_PATH"
