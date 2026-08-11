#!/bin/zsh
set -euo pipefail

if [[ $# -ne 3 ]]; then
  print -u2 "Usage: $0 <archive.zip> <Sparkle sign_update> <output.xml>"
  exit 64
fi

ARCHIVE="$1"
SIGN_UPDATE="$2"
OUTPUT="$3"
BASE_DIR="$(cd "$(dirname "$0")/.." && pwd)"
INFO_PLIST="$BASE_DIR/Memory Widget.app/Contents/Info.plist"

: "${SPARKLE_PRIVATE_KEY:?SPARKLE_PRIVATE_KEY is required}"

[[ -f "$ARCHIVE" ]] || { print -u2 "Archive not found: $ARCHIVE"; exit 66; }
[[ -x "$SIGN_UPDATE" ]] || { print -u2 "sign_update not executable: $SIGN_UPDATE"; exit 66; }
[[ -f "$INFO_PLIST" ]] || { print -u2 "Built app Info.plist not found: $INFO_PLIST"; exit 66; }

SHORT_VERSION="$(plutil -extract CFBundleShortVersionString raw "$INFO_PLIST")"
BUILD_VERSION="$(plutil -extract CFBundleVersion raw "$INFO_PLIST")"
ARCHIVE_NAME="$(basename "$ARCHIVE")"
EXPECTED_ARCHIVE="Memory-Widget-v${SHORT_VERSION}-macos-arm64.zip"

[[ "$ARCHIVE_NAME" == "$EXPECTED_ARCHIVE" ]] || {
  print -u2 "Archive name $ARCHIVE_NAME does not match app version $SHORT_VERSION"
  exit 65
}

SIGNING_ATTRIBUTES="$(print -rn -- "$SPARKLE_PRIVATE_KEY" | "$SIGN_UPDATE" --ed-key-file - "$ARCHIVE")"
ED_SIGNATURE="$(print -r -- "$SIGNING_ATTRIBUTES" | sed -n 's/.*sparkle:edSignature="\([^"]*\)".*/\1/p')"

[[ -n "$ED_SIGNATURE" ]] || { print -u2 "Could not parse Sparkle signature"; exit 65; }

print -rn -- "$SPARKLE_PRIVATE_KEY" | \
  "$SIGN_UPDATE" --verify --ed-key-file - "$ARCHIVE" "$ED_SIGNATURE"

RELEASE_NOTES="$(awk -v header="## ${SHORT_VERSION} -" '
  index($0, header) == 1 { capture = 1; next }
  capture && /^## / { exit }
  capture { print }
' "$BASE_DIR/CHANGELOG.md")"

[[ -n "$RELEASE_NOTES" ]] || RELEASE_NOTES="Secure updater release."

TAG="v${SHORT_VERSION}"
RELEASE_URL="https://github.com/mrdewclau/memory-widget/releases/tag/${TAG}"
ARCHIVE_URL="https://github.com/mrdewclau/memory-widget/releases/download/${TAG}/${ARCHIVE_NAME}"
PUB_DATE="$(LC_ALL=C date -R)"

mkdir -p "$(dirname "$OUTPUT")"
cat > "$OUTPUT" <<XML
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0"
     xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>Memory Widget Updates</title>
    <link>https://github.com/mrdewclau/memory-widget</link>
    <description>Secure stable releases for Memory Widget.</description>
    <language>en</language>
    <item>
      <title>Memory Widget ${SHORT_VERSION}</title>
      <link>${RELEASE_URL}</link>
      <sparkle:version>${BUILD_VERSION}</sparkle:version>
      <sparkle:shortVersionString>${SHORT_VERSION}</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>14.0.0</sparkle:minimumSystemVersion>
      <sparkle:hardwareRequirements>arm64</sparkle:hardwareRequirements>
      <pubDate>${PUB_DATE}</pubDate>
      <description sparkle:format="markdown"><![CDATA[
${RELEASE_NOTES}
      ]]></description>
      <enclosure
          url="${ARCHIVE_URL}"
          ${SIGNING_ATTRIBUTES}
          type="application/octet-stream" />
    </item>
  </channel>
</rss>
XML

xmllint --noout "$OUTPUT"
print -rn -- "$SPARKLE_PRIVATE_KEY" | \
  "$SIGN_UPDATE" --ed-key-file - --disable-signing-warning "$OUTPUT"
print -rn -- "$SPARKLE_PRIVATE_KEY" | \
  "$SIGN_UPDATE" --verify --ed-key-file - "$OUTPUT"
xmllint --noout "$OUTPUT"

print "Created signed appcast: $OUTPUT"
