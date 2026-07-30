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
OUTPUT_DIR="${OUTPUT_DIR:-$ROOT/dist}"
CODESIGN_IDENTITY="${CODESIGN_IDENTITY:--}"
NOTARY_PROFILE="${NOTARY_PROFILE:-}"
APP_PATH="${APP_PATH:-}"
# Universal by default so one download serves Apple silicon and Intel.
ARCHS="${ARCHS:-arm64 x86_64}"
# The committed download lives at the repository root, outside ignored dist/.
ZIP_PATH="${ZIP_PATH:-$ROOT/EQ-for-Mac.zip}"

if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+([.-][0-9A-Za-z.-]+)?$ ]]; then
  echo "VERSION must look like 1.2.3 (received: $VERSION)" >&2
  exit 1
fi

mkdir -p "$OUTPUT_DIR"
WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/eq-for-mac-zip.XXXXXX")"
cleanup() {
  rm -rf "$WORK_DIR"
}
trap cleanup EXIT

if [[ -z "$APP_PATH" ]]; then
  APP_BUILD_DIR="$WORK_DIR/build"
  VERSION="$VERSION" \
  BUILD_NUMBER="$BUILD_NUMBER" \
  OUTPUT_DIR="$APP_BUILD_DIR" \
  CODESIGN_IDENTITY="$CODESIGN_IDENTITY" \
  ARCHS="$ARCHS" \
    "$ROOT/scripts/build-app.sh"
  APP_PATH="$APP_BUILD_DIR/$APP_NAME.app"
fi

if [[ ! -d "$APP_PATH" ]]; then
  echo "Application bundle not found: $APP_PATH" >&2
  exit 1
fi

codesign --verify --deep --strict --verbose=2 "$APP_PATH"

if [[ -n "$NOTARY_PROFILE" ]]; then
  if [[ "$CODESIGN_IDENTITY" == "-" ]]; then
    echo "NOTARY_PROFILE requires a Developer ID CODESIGN_IDENTITY." >&2
    exit 1
  fi
  # notarytool takes a zip, but the ticket staples to the .app — so submit a
  # throwaway archive, staple the bundle, and let the download be re-archived
  # from the stapled bundle below.
  SUBMIT_ZIP="$WORK_DIR/submit.zip"
  /usr/bin/ditto -c -k --keepParent "$APP_PATH" "$SUBMIT_ZIP"
  xcrun notarytool submit "$SUBMIT_ZIP" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$APP_PATH"
  xcrun stapler validate "$APP_PATH"
fi

# ditto, never zip: the zip command drops symlinks, resource forks, and extended
# attributes, which invalidates the code signature and produces an app that
# refuses to launch on Apple silicon. Archive into the work directory so a
# failure never leaves a half-written download at the published path.
STAGED_ZIP="$WORK_DIR/archive.zip"
/usr/bin/ditto -c -k --keepParent "$APP_PATH" "$STAGED_ZIP"

# Verify the artifact people actually download, not just the bundle that went
# into it. A broken archive should fail here rather than on a stranger's Mac.
VERIFY_DIR="$WORK_DIR/verify"
/usr/bin/ditto -x -k "$STAGED_ZIP" "$VERIFY_DIR"
VERIFY_APP="$VERIFY_DIR/$APP_NAME.app"
codesign --verify --deep --strict --verbose=2 "$VERIFY_APP"
SHIPPED_VERSION="$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$VERIFY_APP/Contents/Info.plist")"
SHIPPED_BUILD="$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$VERIFY_APP/Contents/Info.plist")"
SHIPPED_ARCHS="$(lipo -archs "$VERIFY_APP/Contents/MacOS/$EXECUTABLE_NAME")"

mkdir -p "$(dirname "$ZIP_PATH")"
rm -f "$ZIP_PATH"
mv "$STAGED_ZIP" "$ZIP_PATH"

echo ""
echo "Packaged: $ZIP_PATH"
echo "Version:  $SHIPPED_VERSION ($SHIPPED_BUILD)"
echo "Archs:    $SHIPPED_ARCHS"
echo "Size:     $(du -h "$ZIP_PATH" | cut -f1)"
shasum -a 256 "$ZIP_PATH"
