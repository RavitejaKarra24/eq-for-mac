#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

APP_NAME="EQ for Mac"
EXECUTABLE_NAME="EQForMac"
SOURCE_PLIST="$ROOT/Sources/EQForMac/Info.plist"
# Info.plist is the single source of truth for the version; bump it there.
VERSION="${VERSION:-$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$SOURCE_PLIST")}"
BUILD_NUMBER="${BUILD_NUMBER:-$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$SOURCE_PLIST")}"
CONFIGURATION="${CONFIGURATION:-release}"
OUTPUT_DIR="${OUTPUT_DIR:-$ROOT/dist}"
ARCHS="${ARCHS:-}"
PREBUILT_BIN_DIR="${PREBUILT_BIN_DIR:-}"
CODESIGN_IDENTITY="${CODESIGN_IDENTITY:--}"

if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+([.-][0-9A-Za-z.-]+)?$ ]]; then
  echo "VERSION must look like 1.2.3 (received: $VERSION)" >&2
  exit 1
fi

if [[ ! "$BUILD_NUMBER" =~ ^[0-9]+$ ]]; then
  echo "BUILD_NUMBER must be an integer (received: $BUILD_NUMBER)" >&2
  exit 1
fi

build_args=(-c "$CONFIGURATION")
if swift build --help 2>/dev/null | grep -q "swiftbuild"; then
  # Newer standalone Command Line Tools can lack native xcbuild support. The
  # Swift Build engine works without a full Xcode installation.
  build_args=(--build-system swiftbuild "${build_args[@]}")
fi
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
rm -rf "$APP_PATH"
mkdir -p "$APP_PATH/Contents/MacOS" "$APP_PATH/Contents/Resources"

ditto "$BIN" "$APP_PATH/Contents/MacOS/$EXECUTABLE_NAME"
chmod +x "$APP_PATH/Contents/MacOS/$EXECUTABLE_NAME"
ditto "Sources/EQForMac/Resources/AppIcon.icns" "$APP_PATH/Contents/Resources/AppIcon.icns"
ditto "Sources/EQForMac/Info.plist" "$APP_PATH/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$APP_PATH/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_NUMBER" "$APP_PATH/Contents/Info.plist"

SOURCE_RESOURCE_BUNDLE="$BIN_DIR/EQForMac_EQForMac.bundle"
if [[ ! -d "$SOURCE_RESOURCE_BUNDLE" ]]; then
  echo "Build failed: SwiftPM resource bundle not found at $SOURCE_RESOURCE_BUNDLE" >&2
  exit 1
fi

RESOURCE_BUNDLE="$APP_PATH/Contents/Resources/EQForMac_EQForMac.bundle"
if [[ -d "$SOURCE_RESOURCE_BUNDLE/Contents/Resources" ]]; then
  # Swift Build already emits a standard macOS resource bundle.
  ditto "$SOURCE_RESOURCE_BUNDLE" "$RESOURCE_BUNDLE"
else
  # The native SwiftPM builder emits a flat bundle. Convert it to the standard
  # layout required for a nested bundle inside a signed macOS app.
  RESOURCE_CONTENTS="$RESOURCE_BUNDLE/Contents/Resources"
  mkdir -p "$RESOURCE_CONTENTS"
  ditto "$SOURCE_RESOURCE_BUNDLE" "$RESOURCE_CONTENTS"

  RESOURCE_PLIST="$RESOURCE_BUNDLE/Contents/Info.plist"
  /usr/libexec/PlistBuddy -c "Add :CFBundleIdentifier string com.eqformac.app.resources" "$RESOURCE_PLIST"
  /usr/libexec/PlistBuddy -c "Add :CFBundleName string EQForMac_EQForMac" "$RESOURCE_PLIST"
  /usr/libexec/PlistBuddy -c "Add :CFBundlePackageType string BNDL" "$RESOURCE_PLIST"
  /usr/libexec/PlistBuddy -c "Add :CFBundleVersion string $BUILD_NUMBER" "$RESOURCE_PLIST"
  /usr/libexec/PlistBuddy -c "Add :CFBundleShortVersionString string $VERSION" "$RESOURCE_PLIST"
fi

codesign_args=(--force --sign "$CODESIGN_IDENTITY")
if [[ "$CODESIGN_IDENTITY" == "-" ]]; then
  echo "Ad-hoc signing app…"
  codesign_args+=(--timestamp=none)
else
  echo "Signing app with identity: $CODESIGN_IDENTITY"
  codesign_args+=(--options runtime --timestamp)
fi

codesign "${codesign_args[@]}" "$RESOURCE_BUNDLE"
codesign "${codesign_args[@]}" "$APP_PATH"

codesign --verify --deep --strict --verbose=2 "$APP_PATH"
plutil -lint "$APP_PATH/Contents/Info.plist"

echo "Built: $APP_PATH"
