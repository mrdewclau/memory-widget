# Privacy

Memory Widget is local-first. The application contains no analytics SDK, advertising SDK, cloud client, remote model, account system, or automatic updater. It does not transmit RAM telemetry, process names, screen content, camera frames, audio, or derived context.

## Data processed

| Data | Purpose | Retention |
| --- | --- | --- |
| Physical-memory counters | Render RAM composition and history | Rolling 24-hour JSON history |
| Process names, paths, parents, and resident size | Group app footprints and explain process provenance | Current live state only |
| Foreground app, input idle time, CPU, audio-producing apps | Infer whether the user or Mac is active | Bounded derived timeline |
| Camera stills | Local person/animal presence classification | Raw evidence removed after seven days |
| Microphone ring | Local sound-event classification | Fixed 30-second in-memory ring; exported evidence removed after seven days |
| Screen stills | Local OCR context | Disabled until existing permission is verified; evidence removed after seven days |

## Permissions

Camera and microphone access are requested only through macOS and only when their status has never been determined. The attempt is persisted before requesting so a crash cannot create a prompt loop.

Memory Widget never calls the macOS Screen Recording request API and never opens System Settings. Screen capture remains disabled unless the user clicks the SCREEN indicator and macOS reports that access already exists.

## MCP

The MCP server uses stdio only. It exposes the live state, footprint provenance, saved RAM history, and Context Observatory to a local agent that the user has explicitly configured. It does not listen on TCP/UDP and does not provide remote authentication because it has no remote transport.

Any local agent with access to the MCP server can read these local summaries. Only register the server with agents you trust.

## Removing data

Quit Memory Widget and remove this directory:

```text
~/Library/Application Support/Memory Widget/
```

The app will recreate an empty directory the next time it runs.
