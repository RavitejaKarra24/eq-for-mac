#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 2 ]]; then
  echo "Usage: scripts/update-cask.sh VERSION SHA256" >&2
  exit 1
fi

VERSION="$1"
SHA256="$2"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CASK_PATH="$ROOT/Casks/eq-for-mac.rb"

if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "VERSION must look like 1.2.3 (received: $VERSION)" >&2
  exit 1
fi

if [[ ! "$SHA256" =~ ^[0-9a-f]{64}$ ]]; then
  echo "SHA256 must be 64 lowercase hexadecimal characters" >&2
  exit 1
fi

perl -0pi -e 's/version (?:"[^"]+"|:latest)/version "'"$VERSION"'"/;' "$CASK_PATH"
perl -0pi -e 's/sha256 (?:"[0-9a-f]+"|:no_check)/sha256 "'"$SHA256"'"/;' "$CASK_PATH"

if ! grep -Fq 'version "'"$VERSION"'"' "$CASK_PATH" || ! grep -Fq 'sha256 "'"$SHA256"'"' "$CASK_PATH"; then
  echo "Failed to update $CASK_PATH" >&2
  exit 1
fi
