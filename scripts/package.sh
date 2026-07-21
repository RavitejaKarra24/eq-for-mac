#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

APP_NAME="EQ for Mac"
EXECUTABLE_NAME="EQForMac"
VERSION="${VERSION:-1.0.0}"
BUILD_NUMBER="${BUILD_NUMBER:-1}"
CONFIGURATION="${CONFIGURATION:-release}"
OUTPUT_DIR="${OUTPUT_DIR:-$ROOT/dist}"
CODESIGN_IDENTITY="${CODESIGN_IDENTITY:--}"
ARCHS="${ARCHS:-}"
CREATE_DMG="${CREATE_DMG:-1}"
PREBUILT_BIN_DIR="${PREBUILT_BIN_DIR:-}"

if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+([.-][0-9A-Za-z.-]+)?$ ]]; then
  echo "VERSION must look like 1.2.3 (received: $VERSION)" >&2
  exit 1
fi

if [[ ! "$BUILD_NUMBER" =~ ^[0-9]+$ ]]; then
  echo "BUILD_NUMBER must be an integer (received: $BUILD_NUMBER)" >&2
  exit 1
fi

build_args=(-c "$CONFIGURATION")
if [[ -n "$ARCHS" ]]; then
  for arch in $ARCHS; do
    build_args+=(--arch "$arch")
  done
fi

if [[ -z "$PREBUILT_BIN_DIR" ]]; then
  echo "Building $APP_NAME $VERSION ($BUILD_NUMBER)…"
  swift build "${build_args[@]}"
  BIN_DIR="$(swift build "${build_args[@]}" --show-bin-path)"
else
  echo "Packaging prebuilt $APP_NAME $VERSION ($BUILD_NUMBER)…"
  BIN_DIR="$PREBUILT_BIN_DIR"
fi
BIN="$BIN_DIR/$EXECUTABLE_NAME"

if [[ ! -x "$BIN" ]]; then
  echo "Build failed: executable not found at $BIN" >&2
  exit 1
fi

mkdir -p "$OUTPUT_DIR"
APP_PATH="$OUTPUT_DIR/$APP_NAME.app"
DMG_PATH="$OUTPUT_DIR/EQ-for-Mac-$VERSION.dmg"
rm -rf "$APP_PATH"
rm -f "$DMG_PATH"
mkdir -p "$APP_PATH/Contents/MacOS" "$APP_PATH/Contents/Resources"

ditto "$BIN" "$APP_PATH/Contents/MacOS/$EXECUTABLE_NAME"
chmod +x "$APP_PATH/Contents/MacOS/$EXECUTABLE_NAME"
ditto "Sources/EQForMac/Resources/AppIcon.icns" "$APP_PATH/Contents/Resources/AppIcon.icns"
ditto "Sources/EQForMac/Info.plist" "$APP_PATH/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$APP_PATH/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_NUMBER" "$APP_PATH/Contents/Info.plist"

# Bundle.module looks for this SwiftPM resource bundle beside the executable.
RESOURCE_BUNDLE="$BIN_DIR/EQForMac_EQForMac.bundle"
if [[ ! -d "$RESOURCE_BUNDLE" ]]; then
  echo "Build failed: SwiftPM resource bundle not found at $RESOURCE_BUNDLE" >&2
  exit 1
fi
ditto "$RESOURCE_BUNDLE" "$APP_PATH/Contents/MacOS/EQForMac_EQForMac.bundle"

# A minimal bundle plist keeps validation and signing tools happy.
RESOURCE_PLIST="$APP_PATH/Contents/MacOS/EQForMac_EQForMac.bundle/Info.plist"
if [[ ! -f "$RESOURCE_PLIST" ]]; then
  /usr/libexec/PlistBuddy -c "Add :CFBundleIdentifier string com.eqformac.app.resources" "$RESOURCE_PLIST"
  /usr/libexec/PlistBuddy -c "Add :CFBundleName string EQForMac_EQForMac" "$RESOURCE_PLIST"
  /usr/libexec/PlistBuddy -c "Add :CFBundlePackageType string BNDL" "$RESOURCE_PLIST"
  /usr/libexec/PlistBuddy -c "Add :CFBundleVersion string $BUILD_NUMBER" "$RESOURCE_PLIST"
  /usr/libexec/PlistBuddy -c "Add :CFBundleShortVersionString string $VERSION" "$RESOURCE_PLIST"
fi

if [[ "$CODESIGN_IDENTITY" == "-" ]]; then
  echo "Ad-hoc signing app…"
  codesign --force --sign - --timestamp=none "$APP_PATH/Contents/MacOS/EQForMac_EQForMac.bundle"
  codesign --force --sign - --timestamp=none "$APP_PATH"
else
  echo "Signing app with Developer ID…"
  codesign --force --sign "$CODESIGN_IDENTITY" --timestamp "$APP_PATH/Contents/MacOS/EQForMac_EQForMac.bundle"
  codesign --force --sign "$CODESIGN_IDENTITY" --options runtime --timestamp "$APP_PATH"
fi

codesign --verify --deep --strict --verbose=2 "$APP_PATH"
plutil -lint "$APP_PATH/Contents/Info.plist"

if [[ "$CREATE_DMG" == "1" ]]; then
  STAGING_DIR="$(mktemp -d "${TMPDIR:-/tmp}/eq-for-mac-dmg.XXXXXX")"
  trap 'rm -rf "$STAGING_DIR"' EXIT
  ditto "$APP_PATH" "$STAGING_DIR/$APP_NAME.app"
  ln -s /Applications "$STAGING_DIR/Applications"

  echo "Creating ${DMG_PATH}…"
  hdiutil create \
    -volname "$APP_NAME" \
    -srcfolder "$STAGING_DIR" \
    -ov \
    -format UDZO \
    "$DMG_PATH"
  (
    cd "$OUTPUT_DIR"
    shasum -a 256 "$(basename "$DMG_PATH")" > "$(basename "$DMG_PATH").sha256"
  )
fi

echo "Packaged: $APP_PATH"
if [[ "$CREATE_DMG" == "1" ]]; then
  echo "Packaged: $DMG_PATH"
fi
