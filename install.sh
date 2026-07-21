#!/usr/bin/env bash
set -euo pipefail

APP_NAME="EQ for Mac"
INSTALL_DIR="${INSTALL_DIR:-$HOME/Applications}"
APP_PATH="$INSTALL_DIR/$APP_NAME.app"
ROOT="$(cd "$(dirname "$0")" && pwd)"
PACKAGE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/eq-for-mac-install.XXXXXX")"
trap 'rm -rf "$PACKAGE_DIR"' EXIT

OUTPUT_DIR="$PACKAGE_DIR" CREATE_DMG=0 "$ROOT/scripts/package.sh"

echo "→ Creating app bundle at $APP_PATH"
rm -rf "$APP_PATH"
mkdir -p "$INSTALL_DIR"
ditto "$PACKAGE_DIR/$APP_NAME.app" "$APP_PATH"

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
echo "  1. Try opening it once."
echo "  2. Open System Settings → Privacy & Security."
echo "  3. Click Open Anyway beside the EQ for Mac message."
echo ""
echo "Advanced app-only fallback:"
echo "  xattr -dr com.apple.quarantine \"$APP_PATH\""
