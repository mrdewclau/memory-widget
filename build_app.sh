#!/bin/zsh
set -euo pipefail

BASE_DIR="$(cd "$(dirname "$0")" && pwd)"
if [[ -n "${MEMORY_WIDGET_SIGNING_IDENTITY:-}" ]]; then
  SIGNING_IDENTITY="$MEMORY_WIDGET_SIGNING_IDENTITY"
else
  SIGNING_IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null | awk '/Apple Development:/{print $2; exit}')"
  SIGNING_IDENTITY="${SIGNING_IDENTITY:--}"
fi
APP_DIR="$BASE_DIR/Memory Widget.app"
CONTENTS="$APP_DIR/Contents"
MACOS="$CONTENTS/MacOS"
RESOURCES="$CONTENTS/Resources"
ICON_BUILD="$BASE_DIR/.build/MemoryWidget.iconset"
ICON_SOURCE_PNG="$BASE_DIR/.build/MemoryWidgetIcon.svg.png"

rm -rf "$APP_DIR"
rm -rf "$BASE_DIR/.build"
mkdir -p "$MACOS" "$RESOURCES" "$ICON_BUILD"

swiftc "$BASE_DIR/MemoryWidget.swift" \
  "$BASE_DIR/ContextObservatory.swift" \
  "$BASE_DIR/MCPStateBridge.swift" \
  -o "$MACOS/MemoryWidget" \
  -framework AppKit \
  -framework AVFoundation \
  -framework CoreAudio \
  -framework CoreGraphics \
  -framework CoreImage \
  -framework ImageIO \
  -framework ScreenCaptureKit \
  -framework SwiftUI \
  -parse-as-library \
  -target arm64-apple-macosx14.0 \
  -O

swiftc "$BASE_DIR/ContextVisionHelper.swift" \
  -o "$MACOS/ContextVisionHelper" \
  -framework CoreGraphics \
  -framework ImageIO \
  -framework Vision \
  -parse-as-library \
  -target arm64-apple-macosx14.0 \
  -O

swiftc "$BASE_DIR/ContextSoundHelper.swift" \
  -o "$MACOS/ContextSoundHelper" \
  -framework SoundAnalysis \
  -parse-as-library \
  -target arm64-apple-macosx14.0 \
  -O

swiftc "$BASE_DIR/MemoryWidgetMCP.swift" \
  -o "$MACOS/MemoryWidgetMCP" \
  -parse-as-library \
  -target arm64-apple-macosx14.0 \
  -O

qlmanage -t -s 1024 -o "$BASE_DIR/.build" "$BASE_DIR/MemoryWidgetIcon.svg" >/dev/null 2>&1
for spec in \
  "16 icon_16x16.png" \
  "32 icon_16x16@2x.png" \
  "32 icon_32x32.png" \
  "64 icon_32x32@2x.png" \
  "128 icon_128x128.png" \
  "256 icon_128x128@2x.png" \
  "256 icon_256x256.png" \
  "512 icon_256x256@2x.png" \
  "512 icon_512x512.png" \
  "1024 icon_512x512@2x.png"; do
  size="${spec%% *}"
  name="${spec#* }"
  sips -z "$size" "$size" "$ICON_SOURCE_PNG" --out "$ICON_BUILD/$name" >/dev/null
done
iconutil -c icns "$ICON_BUILD" -o "$RESOURCES/MemoryWidget.icns"
rm -rf "$BASE_DIR/.build"

cat > "$CONTENTS/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleDisplayName</key>
	<string>Memory Widget</string>
	<key>CFBundleExecutable</key>
	<string>MemoryWidget</string>
	<key>CFBundleIdentifier</key>
	<string>local.memory-widget</string>
	<key>CFBundleIconFile</key>
	<string>MemoryWidget</string>
	<key>CFBundleName</key>
	<string>Memory Widget</string>
	<key>CFBundlePackageType</key>
	<string>APPL</string>
	<key>CFBundleShortVersionString</key>
	<string>2.1.1</string>
	<key>CFBundleVersion</key>
	<string>13</string>
	<key>LSMinimumSystemVersion</key>
	<string>14.0</string>
	<key>LSUIElement</key>
	<false/>
	<key>NSCameraUsageDescription</key>
	<string>Memory Widget uses brief local camera observations to explain whether RAM activity matches you, the room, or the Mac working alone.</string>
	<key>NSMicrophoneUsageDescription</key>
	<string>Memory Widget keeps a fixed 30-second local audio ring and classifies sound events to explain RAM activity in context.</string>
	<key>NSScreenCaptureUsageDescription</key>
	<string>Memory Widget takes occasional local screen snapshots so memory changes can be connected to the work visible on this Mac.</string>
	<key>NSAudioCaptureUsageDescription</key>
	<string>Memory Widget analyzes local audio context to distinguish active use, playback, room activity, and quiet periods.</string>
</dict>
</plist>
PLIST

codesign --force --sign "$SIGNING_IDENTITY" "$MACOS/ContextVisionHelper" >/dev/null
codesign --force --sign "$SIGNING_IDENTITY" "$MACOS/ContextSoundHelper" >/dev/null
codesign --force --sign "$SIGNING_IDENTITY" "$MACOS/MemoryWidgetMCP" >/dev/null
codesign --force --deep --sign "$SIGNING_IDENTITY" "$APP_DIR" >/dev/null
echo "Built: $APP_DIR"
