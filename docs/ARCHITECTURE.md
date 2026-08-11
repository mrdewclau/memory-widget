# Architecture

Memory Widget is a dependency-free native Swift application compiled directly with `swiftc`.

```text
macOS VM statistics + process samples
                  │
                  ▼
            MemoryMonitor
             │          │
             │          └── rolling memory-history.json
             ▼
     SwiftUI widget + menu bar
             │
             └── ContextObservatory
                    ├── fixed audio ring
                    ├── burst camera session
                    ├── local Vision helper
                    ├── local Sound Analysis helper
                    └── bounded context JSONL + evidence retention

MemoryMonitor + ContextObservatory
                  │
                  ▼
          mcp-live-state.json
                  │
                  ▼
      MemoryWidgetMCP (stdio only)
```

## Resource policy

- Physical memory refresh: two seconds.
- Process-footprint refresh: five seconds, one in-flight sample.
- MCP state: one small atomically replaced JSON document, not an append-only stream.
- UI memory history: bounded; disk history: rolling 24 hours.
- Audio: fixed 30 seconds at 16 kHz mono.
- Camera: session starts for a still and stops immediately.
- Analysis helpers: short-lived and serialized.
- Context UI history: 480 points.
- Raw evidence: removed after seven days.
- Memory pressure: rich context collection pauses for two minutes.

## Trust boundaries

The app reads operating-system and current-user process metadata. Camera, microphone, and screen content cross macOS privacy boundaries only after operating-system authorization. The MCP server crosses a separate local trust boundary: configured agents can read the published summaries and ask macOS to open the app, but cannot alter processes, permissions, histories, or capture schedules through MCP.
