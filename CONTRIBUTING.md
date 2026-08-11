# Contributing

## Development

1. Use an Apple Silicon Mac running macOS 14 or newer.
2. Install Xcode Command Line Tools.
3. Run `./build_app.sh`.
4. Run `./test_mcp.sh`.
5. Double-click the generated app for visual verification.

Keep the interface glanceable, viewport-contained, and consistent with the existing visual system. New telemetry must have a bounded memory footprint, bounded retention, a clear plain-language explanation, and no remote transmission by default.

## Pull requests

- Keep changes focused.
- Explain user-visible behavior and privacy impact.
- Add or update deterministic tests for protocol or persistence changes.
- Do not commit app bundles, evidence, histories, credentials, signing identities, absolute home-directory paths, or generated archives.
- Confirm `./build_app.sh` and `./test_mcp.sh` pass before requesting review.

## Security-sensitive changes

Changes to permissions, capture, process inspection, persistence, MCP tools, or external communication require an explicit threat-model note in the pull request.
