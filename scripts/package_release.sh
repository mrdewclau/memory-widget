#!/bin/zsh
set -euo pipefail

BASE_DIR="$(cd "$(dirname "$0")/.." && pwd)"
DIST_DIR="$BASE_DIR/dist"

cd "$BASE_DIR"
pkill -x MemoryWidget >/dev/null 2>&1 || true
./build_app.sh

VERSION="$(plutil -extract CFBundleShortVersionString raw 'Memory Widget.app/Contents/Info.plist')"
ARCHIVE="$DIST_DIR/Memory-Widget-v${VERSION}-macos-arm64.zip"

rm -rf "$DIST_DIR"
mkdir -p "$DIST_DIR"
ditto -c -k --norsrc --keepParent "Memory Widget.app" "$ARCHIVE"
shasum -a 256 "$ARCHIVE" > "$ARCHIVE.sha256"

print "Created: $ARCHIVE"
print "Checksum: $ARCHIVE.sha256"
