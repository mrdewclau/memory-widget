#!/bin/zsh
set -euo pipefail

BASE_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP="$BASE_DIR/Memory Widget.app"
INFO="$APP/Contents/Info.plist"
FRAMEWORK="$APP/Contents/Frameworks/Sparkle.framework"
EXPECTED_PUBLIC_KEY='a95jtwpswOF3OPTITNyTAC62wpytf4xoFf852++7Iuw='
EXPECTED_FEED='https://github.com/mrdewclau/memory-widget/releases/latest/download/appcast.xml'

fail() {
  print -u2 "Updater test failed: $1"
  exit 1
}

[[ -f "$INFO" ]] || fail "build Memory Widget.app first"
[[ -d "$FRAMEWORK" ]] || fail "Sparkle.framework is missing"

[[ "$(plutil -extract SUFeedURL raw "$INFO")" == "$EXPECTED_FEED" ]] || fail "unexpected feed URL"
[[ "$(plutil -extract SUPublicEDKey raw "$INFO")" == "$EXPECTED_PUBLIC_KEY" ]] || fail "unexpected public key"
[[ "$(plutil -extract SUEnableAutomaticChecks raw "$INFO")" == "true" ]] || fail "automatic discovery is not enabled"
[[ "$(plutil -extract SUScheduledCheckInterval raw "$INFO")" == "86400" ]] || fail "update interval is not one day"
[[ "$(plutil -extract SUAutomaticallyUpdate raw "$INFO")" == "false" ]] || fail "silent installation must remain disabled"
[[ "$(plutil -extract SUAllowsAutomaticUpdates raw "$INFO")" == "false" ]] || fail "automatic installation must remain unavailable"
[[ "$(plutil -extract SUEnableSystemProfiling raw "$INFO")" == "false" ]] || fail "system profiling must remain disabled"
[[ "$(plutil -extract SUVerifyUpdateBeforeExtraction raw "$INFO")" == "true" ]] || fail "pre-extraction verification is not enabled"
[[ "$(plutil -extract SURequireSignedFeed raw "$INFO")" == "true" ]] || fail "signed feeds are not required"

[[ "$(plutil -extract CFBundleShortVersionString raw "$FRAMEWORK/Resources/Info.plist")" == "2.9.5" ]] || fail "unexpected Sparkle framework version"
[[ "$(jq -r '.pins[] | select(.identity == "sparkle") | .state.version' "$BASE_DIR/Package.resolved")" == "2.9.5" ]] || fail "Package.resolved does not pin Sparkle 2.9.5"

codesign --verify --deep --strict "$APP"
otool -L "$APP/Contents/MacOS/MemoryWidget" | grep -q '@rpath/Sparkle.framework/' || fail "app does not link bundled Sparkle"
otool -l "$APP/Contents/MacOS/MemoryWidget" | grep -A2 LC_RPATH | grep -q '@executable_path/../Frameworks' || fail "app cannot locate bundled Sparkle"

if [[ $# -eq 0 ]]; then
  print "Updater bundle configuration passed."
  exit 0
fi

[[ $# -eq 2 ]] || fail "usage: $0 [<sign_update> <appcast.xml>]"
SIGN_UPDATE="$1"
APPCAST="$2"
: "${SPARKLE_PRIVATE_KEY:?SPARKLE_PRIVATE_KEY is required for signed artifact tests}"

[[ -x "$SIGN_UPDATE" ]] || fail "sign_update is not executable"
[[ -f "$APPCAST" ]] || fail "appcast does not exist"
xmllint --noout "$APPCAST"

ARCHIVE_URL="$(xmllint --xpath "string(//*[local-name()='enclosure']/@url)" "$APPCAST")"
ARCHIVE_SIGNATURE="$(xmllint --xpath "string(//*[local-name()='enclosure']/@*[local-name()='edSignature'])" "$APPCAST")"
ARCHIVE="$BASE_DIR/dist/$(basename "$ARCHIVE_URL")"

[[ -f "$ARCHIVE" ]] || fail "appcast archive is missing"
[[ -n "$ARCHIVE_SIGNATURE" ]] || fail "appcast archive signature is missing"

print -rn -- "$SPARKLE_PRIVATE_KEY" | "$SIGN_UPDATE" --verify --ed-key-file - "$ARCHIVE" "$ARCHIVE_SIGNATURE"
print -rn -- "$SPARKLE_PRIVATE_KEY" | "$SIGN_UPDATE" --verify --ed-key-file - "$APPCAST"

TEMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/memory-widget-updater-test.XXXXXX")"
trap 'rm -rf "$TEMP_DIR"' EXIT

cp "$ARCHIVE" "$TEMP_DIR/tampered.zip"
print -n x >> "$TEMP_DIR/tampered.zip"
if print -rn -- "$SPARKLE_PRIVATE_KEY" | "$SIGN_UPDATE" --verify --ed-key-file - "$TEMP_DIR/tampered.zip" "$ARCHIVE_SIGNATURE" >/dev/null 2>&1; then
  fail "tampered archive was accepted"
fi

cp "$APPCAST" "$TEMP_DIR/tampered.xml"
perl -0pi -e 's/Memory Widget Updates/Memory Widget Altered/' "$TEMP_DIR/tampered.xml"
if print -rn -- "$SPARKLE_PRIVATE_KEY" | "$SIGN_UPDATE" --verify --ed-key-file - "$TEMP_DIR/tampered.xml" >/dev/null 2>&1; then
  fail "tampered appcast was accepted"
fi

print "Signed updater artifacts and tamper rejection passed."
