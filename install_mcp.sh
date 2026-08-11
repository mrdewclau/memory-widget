#!/bin/zsh
set -euo pipefail

BASE_DIR="$(cd "$(dirname "$0")" && pwd)"
SERVER="$BASE_DIR/Memory Widget.app/Contents/MacOS/MemoryWidgetMCP"
CLAUDE_CONFIG="$HOME/Library/Application Support/Claude/claude_desktop_config.json"

if [[ ! -x "$SERVER" ]]; then
  echo "Memory Widget MCP server is not built. Run ./build_app.sh first."
  exit 1
fi

if command -v codex >/dev/null 2>&1; then
  codex mcp remove memory-widget >/dev/null 2>&1 || true
  codex mcp add memory-widget -- "$SERVER" >/dev/null
  echo "Registered with Codex: memory-widget"
fi

if [[ -f "$CLAUDE_CONFIG" ]] && command -v jq >/dev/null 2>&1; then
  CONFIG_TEMP="$(mktemp "${TMPDIR:-/tmp}/memory-widget-claude.XXXXXX")"
  jq --arg server "$SERVER" \
    '.mcpServers = (.mcpServers // {}) | .mcpServers["memory-widget"] = {"command": $server, "args": []}' \
    "$CLAUDE_CONFIG" > "$CONFIG_TEMP"
  mv "$CONFIG_TEMP" "$CLAUDE_CONFIG"
  echo "Registered with Claude Desktop: memory-widget"
fi

echo "MCP server: $SERVER"
