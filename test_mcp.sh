#!/bin/zsh
set -euo pipefail

BASE_DIR="$(cd "$(dirname "$0")" && pwd)"
SERVER="$BASE_DIR/Memory Widget.app/Contents/MacOS/MemoryWidgetMCP"
STATE="$HOME/Library/Application Support/Memory Widget/mcp-live-state.json"

request() {
  "$SERVER" <<< "$1"
}

[[ -x "$SERVER" ]]
open "$BASE_DIR/Memory Widget.app"

for _ in {1..20}; do
  if [[ -f "$STATE" ]] && jq -e '.app.running == true and .memory.totalBytes > 0' "$STATE" >/dev/null 2>&1; then
    break
  fi
  sleep 1
done

jq -e '.app.running == true and .memory.totalBytes > 0 and (.memory.footprints | length) > 0' "$STATE" >/dev/null

LEGACY_INIT='{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"mcp-test","version":"1"}}}'
request "$LEGACY_INIT" | jq -e '.result.protocolVersion == "2025-11-25" and .result.serverInfo.name == "memory-widget"' >/dev/null

LEGACY_LIST='{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}'
request "$LEGACY_LIST" | jq -e '(.result.tools | length) == 5 and (.result.resultType == null)' >/dev/null

MODERN_META='"_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28","io.modelcontextprotocol/clientInfo":{"name":"mcp-test","version":"1"},"io.modelcontextprotocol/clientCapabilities":{}}'
MODERN_DISCOVER="{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"server/discover\",\"params\":{$MODERN_META}}"
request "$MODERN_DISCOVER" | jq -e '.result.resultType == "complete" and (.result.supportedVersions | index("2026-07-28")) != null and .result.ttlMs == 300000' >/dev/null

MODERN_LIST="{\"jsonrpc\":\"2.0\",\"id\":4,\"method\":\"tools/list\",\"params\":{$MODERN_META}}"
request "$MODERN_LIST" | jq -e '.result.resultType == "complete" and (.result.tools | length) == 5 and .result.cacheScope == "private"' >/dev/null

MODERN_SNAPSHOT="{\"jsonrpc\":\"2.0\",\"id\":5,\"method\":\"tools/call\",\"params\":{\"name\":\"get_memory_snapshot\",\"arguments\":{},$MODERN_META}}"
request "$MODERN_SNAPSHOT" | jq -e '.result.resultType == "complete" and .result.isError == false and .result.structuredContent.totalBytes > 0 and .result.structuredContent.usedBytes > 0' >/dev/null

MODERN_FOOTPRINTS="{\"jsonrpc\":\"2.0\",\"id\":6,\"method\":\"tools/call\",\"params\":{\"name\":\"get_memory_footprints\",\"arguments\":{\"limit\":3},$MODERN_META}}"
request "$MODERN_FOOTPRINTS" | jq -e '.result.isError == false and (.result.structuredContent.footprints | length) == 3' >/dev/null

MODERN_HISTORY="{\"jsonrpc\":\"2.0\",\"id\":7,\"method\":\"tools/call\",\"params\":{\"name\":\"get_memory_history\",\"arguments\":{\"minutes\":60,\"maxPoints\":40},$MODERN_META}}"
request "$MODERN_HISTORY" | jq -e '.result.isError == false and .result.structuredContent.available == true and .result.structuredContent.pointCount <= 40' >/dev/null

MODERN_CONTEXT="{\"jsonrpc\":\"2.0\",\"id\":8,\"method\":\"tools/call\",\"params\":{\"name\":\"get_memory_context\",\"arguments\":{},$MODERN_META}}"
request "$MODERN_CONTEXT" | jq -e '.result.isError == false and (.result.structuredContent.context.state | type) == "string" and (.result.structuredContent.recentTimeline | type) == "array"' >/dev/null

MODERN_OPEN="{\"jsonrpc\":\"2.0\",\"id\":9,\"method\":\"tools/call\",\"params\":{\"name\":\"open_memory_widget\",\"arguments\":{},$MODERN_META}}"
request "$MODERN_OPEN" | jq -e '.result.isError == false and .result.structuredContent.opened == true' >/dev/null

MODERN_RESOURCES="{\"jsonrpc\":\"2.0\",\"id\":10,\"method\":\"resources/list\",\"params\":{$MODERN_META}}"
request "$MODERN_RESOURCES" | jq -e '.result.resultType == "complete" and (.result.resources | length) == 3' >/dev/null

MODERN_RESOURCE="{\"jsonrpc\":\"2.0\",\"id\":11,\"method\":\"resources/read\",\"params\":{\"uri\":\"memory-widget://live\",$MODERN_META}}"
request "$MODERN_RESOURCE" | jq -e '.result.resultType == "complete" and (.result.contents | length) == 1 and .result.contents[0].mimeType == "application/json"' >/dev/null

BAD_VERSION='{"jsonrpc":"2.0","id":12,"method":"tools/list","params":{"_meta":{"io.modelcontextprotocol/protocolVersion":"2099-01-01","io.modelcontextprotocol/clientCapabilities":{}}}}'
request "$BAD_VERSION" | jq -e '.error.code == -32020' >/dev/null

print "Memory Widget MCP protocol tests passed."
