#!/bin/zsh
set -euo pipefail

BASE_DIR="$(cd "$(dirname "$0")/.." && pwd)"
MODULE_DIR="$BASE_DIR/.build/codeql"

rm -rf "$MODULE_DIR"
mkdir -p "$MODULE_DIR"

print "CodeQL: emitting MemoryWidget module"
swiftc \
  "$BASE_DIR/MemoryWidget.swift" \
  "$BASE_DIR/ContextObservatory.swift" \
  "$BASE_DIR/MCPStateBridge.swift" \
  -module-name MemoryWidget \
  -emit-module \
  -emit-module-path "$MODULE_DIR/MemoryWidget.swiftmodule" \
  -framework AppKit \
  -framework AVFoundation \
  -framework CoreAudio \
  -framework CoreGraphics \
  -framework CoreImage \
  -framework ImageIO \
  -framework ScreenCaptureKit \
  -framework SwiftUI \
  -parse-as-library \
  -target arm64-apple-macosx14.0

print "CodeQL: emitting ContextVisionHelper module"
swiftc "$BASE_DIR/ContextVisionHelper.swift" \
  -module-name ContextVisionHelper \
  -emit-module \
  -emit-module-path "$MODULE_DIR/ContextVisionHelper.swiftmodule" \
  -framework CoreGraphics \
  -framework ImageIO \
  -framework Vision \
  -parse-as-library \
  -target arm64-apple-macosx14.0

print "CodeQL: emitting ContextSoundHelper module"
swiftc "$BASE_DIR/ContextSoundHelper.swift" \
  -module-name ContextSoundHelper \
  -emit-module \
  -emit-module-path "$MODULE_DIR/ContextSoundHelper.swiftmodule" \
  -framework SoundAnalysis \
  -parse-as-library \
  -target arm64-apple-macosx14.0

print "CodeQL: emitting MemoryWidgetMCP module"
swiftc "$BASE_DIR/MemoryWidgetMCP.swift" \
  -module-name MemoryWidgetMCP \
  -emit-module \
  -emit-module-path "$MODULE_DIR/MemoryWidgetMCP.swiftmodule" \
  -parse-as-library \
  -target arm64-apple-macosx14.0

print "CodeQL: module emission complete"
