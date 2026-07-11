#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
cd "$ROOT"

APP_NAME="EQ for Mac"
BUNDLE_ID="com.eqformac.app"
INSTALL_DIR="${INSTALL_DIR:-$HOME/Applications}"
APP_PATH="$INSTALL_DIR/$APP_NAME.app"

echo "→ Building EQ for Mac (release)…"
swift build -c release

BIN_DIR="$(swift build -c release --show-bin-path)"
BIN="$BIN_DIR/EQForMac"
if [[ ! -x "$BIN" ]]; then
  echo "Build failed: binary not found at $BIN" >&2
  exit 1
fi

echo "→ Creating app bundle at $APP_PATH"
rm -rf "$APP_PATH"
mkdir -p "$APP_PATH/Contents/MacOS"
mkdir -p "$APP_PATH/Contents/Resources"

cp "$BIN" "$APP_PATH/Contents/MacOS/EQForMac"
chmod +x "$APP_PATH/Contents/MacOS/EQForMac"

# Finder, Spotlight, and Open dialogs use this icon to identify the app.
cp "Sources/EQForMac/Resources/AppIcon.icns" "$APP_PATH/Contents/Resources/AppIcon.icns"

# SPM resource bundle (headphone presets) must sit next to the executable.
if [[ -d "$BIN_DIR/EQForMac_EQForMac.bundle" ]]; then
  cp -R "$BIN_DIR/EQForMac_EQForMac.bundle" "$APP_PATH/Contents/MacOS/"
  # Minimal Info.plist so codesign accepts the bundle as a subcomponent.
  cat > "$APP_PATH/Contents/MacOS/EQForMac_EQForMac.bundle/Info.plist" <<'BUNDLE_PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleIdentifier</key>
	<string>com.eqformac.app.resources</string>
	<key>CFBundleName</key>
	<string>EQForMac_EQForMac</string>
	<key>CFBundlePackageType</key>
	<string>BNDL</string>
	<key>CFBundleVersion</key>
	<string>1</string>
	<key>CFBundleShortVersionString</key>
	<string>1.0.0</string>
</dict>
</plist>
BUNDLE_PLIST
fi

# Also keep a plain copy under Resources for manual inspection / fallbacks.
if [[ -d "Sources/EQForMac/Resources/headphones" ]]; then
  cp -R "Sources/EQForMac/Resources/headphones" "$APP_PATH/Contents/Resources/" || true
fi

cat > "$APP_PATH/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleIdentifier</key>
	<string>com.eqformac.app</string>
	<key>CFBundleName</key>
	<string>EQ for Mac</string>
	<key>CFBundleDisplayName</key>
	<string>EQ for Mac</string>
	<key>CFBundleVersion</key>
	<string>1</string>
	<key>CFBundleShortVersionString</key>
	<string>1.0.0</string>
	<key>CFBundlePackageType</key>
	<string>APPL</string>
	<key>CFBundleExecutable</key>
	<string>EQForMac</string>
	<key>CFBundleIconFile</key>
	<string>AppIcon</string>
	<key>LSMinimumSystemVersion</key>
	<string>14.2</string>
	<key>LSUIElement</key>
	<true/>
	<key>NSHighResolutionCapable</key>
	<true/>
	<key>NSMicrophoneUsageDescription</key>
	<string>EQ for Mac processes system audio to apply equalization across all apps.</string>
	<key>NSAudioCaptureUsageDescription</key>
	<string>EQ for Mac captures system audio so EQ can apply to browser, Spotify, Apple Music, and every other app.</string>
	<key>NSScreenCaptureDescription</key>
	<string>macOS requires Screen &amp; System Audio Recording permission for system-wide EQ (Core Audio Taps).</string>
</dict>
</plist>
PLIST

# Ad-hoc sign so TCC permission grants stick across rebuilds better.
if command -v codesign >/dev/null; then
  echo "→ Ad-hoc codesigning…"
  codesign --force --deep --sign - "$APP_PATH" || true
fi

echo ""
echo "Installed: $APP_PATH"
echo ""
echo "Open it with:"
echo "  open \"$APP_PATH\""
echo ""
echo "First run: grant Screen & System Audio Recording when prompted"
echo "(System Settings → Privacy & Security → Screen & System Audio Recording)."
echo ""
echo "If macOS blocks the app:"
echo "  xattr -dr com.apple.quarantine \"$APP_PATH\""
