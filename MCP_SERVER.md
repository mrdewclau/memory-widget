# Memory Widget MCP

Memory Widget includes a local stdio MCP server inside the built app bundle:

```text
Memory Widget.app/Contents/MacOS/MemoryWidgetMCP
```

It exposes live physical-RAM composition, grouped app footprints and provenance, the saved 24-hour RAM timeline, and the local Context Observatory. The only action is opening Memory Widget onscreen. It has no HTTP listener, cloud dependency, authentication secret, or network transport.

## Tools

| Tool | Effect |
| --- | --- |
| `get_memory_snapshot` | Read current used, available, active, wired, and compressed RAM. |
| `get_memory_footprints` | Read app-grouped footprints, roles, purpose, and source evidence. |
| `get_memory_history` | Read a bounded, downsampled window of the saved RAM timeline. |
| `get_memory_context` | Read the current Context Observatory explanation and recent state timeline. |
| `open_memory_widget` | Bring the visual widget onscreen. |

Resources mirror the live state, RAM history, and context history at `memory-widget://live`, `memory-widget://history/ram`, and `memory-widget://history/context`.

The server supports modern MCP `2026-07-28` discovery and per-request metadata plus the legacy `2025-11-25` initialization flow. Run `./install_mcp.sh` after rebuilding to register it with Codex and Claude Desktop. Other local agents can use `./memory-widget-mcp` as a standard stdio MCP command.
