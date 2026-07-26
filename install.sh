#!/usr/bin/env bash
set -euo pipefail

APP_NAME="EQ for Mac"
EXECUTABLE_NAME="EQForMac"
INSTALL_DIR="${INSTALL_DIR:-$HOME/Applications}"
APP_PATH="$INSTALL_DIR/$APP_NAME.app"
ROOT="$(cd "$(dirname "$0")" && pwd)"
BUILD_DIR="$(mktemp -d "${TMPDIR:-/tmp}/eq-for-mac-install.XXXXXX")"
trap 'rm -rf "$BUILD_DIR"' EXIT

if ! xcrun --find swift >/dev/null 2>&1; then
  echo "The Xcode Command Line Tools are required." >&2
  echo "Install them with: xcode-select --install" >&2
  exit 1
fi

echo "→ Building EQ for Mac from the checked-out source"
OUTPUT_DIR="$BUILD_DIR" "$ROOT/scripts/build-app.sh"

echo "→ Installing at $APP_PATH"
pkill -x "$EXECUTABLE_NAME" 2>/dev/null || true
rm -rf "$APP_PATH"
mkdir -p "$INSTALL_DIR"
ditto "$BUILD_DIR/$APP_NAME.app" "$APP_PATH"

# A command-line source checkout normally has no quarantine flag. Removing it
# here also keeps app-specific Gatekeeper metadata from a ZIP checkout out of
# the locally built app. This does not change the Mac's global security policy.
xattr -dr com.apple.quarantine "$APP_PATH" 2>/dev/null || true
codesign --verify --deep --strict "$APP_PATH"

echo "→ Opening EQ for Mac"
open "$APP_PATH"

echo ""
echo "Installed and opened: $APP_PATH"
echo ""
echo "On first use, allow EQ for Mac under:"
echo "  System Settings → Privacy & Security → Screen & System Audio Recording"
echo ""
echo "Future launches:"
echo "  open \"$APP_PATH\""
