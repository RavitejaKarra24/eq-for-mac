#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

VERSION="${VERSION:-1.0.0}"
BUILD_NUMBER="${BUILD_NUMBER:-1}"
OUTPUT_DIR="${OUTPUT_DIR:-$ROOT/dist}"
CODESIGN_IDENTITY="${CODESIGN_IDENTITY:--}"
NOTARY_PROFILE="${NOTARY_PROFILE:-}"
APP_PATH="${APP_PATH:-}"
DMG_PATH="${DMG_PATH:-$OUTPUT_DIR/EQ-for-Mac-$VERSION.dmg}"

if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+([.-][0-9A-Za-z.-]+)?$ ]]; then
  echo "VERSION must look like 1.2.3 (received: $VERSION)" >&2
  exit 1
fi

mkdir -p "$OUTPUT_DIR"
WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/eq-for-mac-dmg.XXXXXX")"
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
    "$ROOT/scripts/build-app.sh"
  APP_PATH="$APP_BUILD_DIR/EQ for Mac.app"
fi

if [[ ! -d "$APP_PATH" ]]; then
  echo "Application bundle not found: $APP_PATH" >&2
  exit 1
fi

codesign --verify --deep --strict --verbose=2 "$APP_PATH"

STAGING_DIR="$WORK_DIR/staging"
mkdir -p "$STAGING_DIR"
ditto "$APP_PATH" "$STAGING_DIR/EQ for Mac.app"
ln -s /Applications "$STAGING_DIR/Applications"

rm -f "$DMG_PATH"
hdiutil create \
  -volname "EQ for Mac" \
  -srcfolder "$STAGING_DIR" \
  -format UDZO \
  -imagekey zlib-level=9 \
  "$DMG_PATH"

if [[ "$CODESIGN_IDENTITY" != "-" ]]; then
  codesign --force --sign "$CODESIGN_IDENTITY" --timestamp "$DMG_PATH"
  codesign --verify --verbose=2 "$DMG_PATH"
fi

if [[ -n "$NOTARY_PROFILE" ]]; then
  if [[ "$CODESIGN_IDENTITY" == "-" ]]; then
    echo "NOTARY_PROFILE requires a Developer ID CODESIGN_IDENTITY." >&2
    exit 1
  fi
  xcrun notarytool submit \
    "$DMG_PATH" \
    --keychain-profile "$NOTARY_PROFILE" \
    --wait
  xcrun stapler staple "$DMG_PATH"
  xcrun stapler validate "$DMG_PATH"
fi

shasum -a 256 "$DMG_PATH"
echo "Packaged: $DMG_PATH"
