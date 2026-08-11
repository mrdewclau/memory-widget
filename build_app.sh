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
FRAMEWORKS="$CONTENTS/Frameworks"
mkdir -p "$BASE_DIR/.build"
ICON_WORK="$(mktemp -d "$BASE_DIR/.build/icon-work.XXXXXX")"
ICON_BUILD="$ICON_WORK/MemoryWidget.iconset"
ICON_SOURCE_PNG="$ICON_WORK/MemoryWidgetIcon.svg.png"

cleanup() {
  rm -rf "$ICON_WORK"
}
trap cleanup EXIT

rm -rf "$APP_DIR"
mkdir -p "$MACOS" "$RESOURCES" "$FRAMEWORKS" "$ICON_BUILD"

cd "$BASE_DIR"
swift build --configuration release --arch arm64
BUILD_PRODUCTS="$(swift build --configuration release --arch arm64 --show-bin-path)"

install -m 755 "$BUILD_PRODUCTS/MemoryWidget" "$MACOS/MemoryWidget"
install -m 755 "$BUILD_PRODUCTS/ContextVisionHelper" "$MACOS/ContextVisionHelper"
install -m 755 "$BUILD_PRODUCTS/ContextSoundHelper" "$MACOS/ContextSoundHelper"
install -m 755 "$BUILD_PRODUCTS/MemoryWidgetMCP" "$MACOS/MemoryWidgetMCP"
ditto "$BUILD_PRODUCTS/Sparkle.framework" "$FRAMEWORKS/Sparkle.framework"

qlmanage -t -s 1024 -o "$ICON_WORK" "$BASE_DIR/MemoryWidgetIcon.svg" >/dev/null
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
	<string>2.2.0</string>
	<key>CFBundleVersion</key>
	<string>14</string>
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
	<key>SUFeedURL</key>
	<string>https://github.com/mrdewclau/memory-widget/releases/latest/download/appcast.xml</string>
	<key>SUPublicEDKey</key>
	<string>a95jtwpswOF3OPTITNyTAC62wpytf4xoFf852++7Iuw=</string>
	<key>SUEnableAutomaticChecks</key>
	<true/>
	<key>SUScheduledCheckInterval</key>
	<integer>86400</integer>
	<key>SUAutomaticallyUpdate</key>
	<false/>
	<key>SUAllowsAutomaticUpdates</key>
	<false/>
	<key>SUEnableSystemProfiling</key>
	<false/>
	<key>SUVerifyUpdateBeforeExtraction</key>
	<true/>
	<key>SURequireSignedFeed</key>
	<true/>
</dict>
</plist>
PLIST

codesign --force --deep --sign "$SIGNING_IDENTITY" "$FRAMEWORKS/Sparkle.framework" >/dev/null
codesign --force --sign "$SIGNING_IDENTITY" "$MACOS/ContextVisionHelper" >/dev/null
codesign --force --sign "$SIGNING_IDENTITY" "$MACOS/ContextSoundHelper" >/dev/null
codesign --force --sign "$SIGNING_IDENTITY" "$MACOS/MemoryWidgetMCP" >/dev/null
codesign --force --deep --sign "$SIGNING_IDENTITY" "$APP_DIR" >/dev/null
echo "Built: $APP_DIR"
