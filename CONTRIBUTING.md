# Contributing

## Development

1. Use an Apple Silicon Mac running macOS 14 or newer.
2. Install Xcode Command Line Tools.
3. Run `./build_app.sh`.
4. Run `./test_mcp.sh`.
5. Run `./scripts/test_updater.sh`.
6. Double-click the generated app for visual verification.

Keep the interface glanceable, viewport-contained, and consistent with the existing visual system. New telemetry must have a bounded memory footprint, bounded retention, a clear plain-language explanation, and no remote transmission by default.

## Pull requests

- Keep changes focused.
- Explain user-visible behavior and privacy impact.
- Add or update deterministic tests for protocol or persistence changes.
- Do not commit app bundles, evidence, histories, credentials, signing identities, absolute home-directory paths, or generated archives.
- Confirm `./build_app.sh` and `./test_mcp.sh` pass before requesting review.

## Security-sensitive changes

Changes to permissions, capture, process inspection, persistence, MCP tools, updater trust, or external communication require an explicit threat-model note in the pull request.

## Releases

1. Update the short version and monotonically increasing build number in `build_app.sh`.
2. Add the matching release section to `CHANGELOG.md`.
3. Merge through a pull request with green CI.
4. Tag the exact merge commit as `vX.Y.Z` and push the tag.
5. Verify the release contains the ZIP, portable SHA-256 file, and signed `appcast.xml`.

The release workflow refuses mismatched tags, downloads checksum-pinned Sparkle tooling, signs through the protected repository secret, and tests valid and tampered artifacts before publishing. Never print, commit, attach, or pass the private update key on a command line. See [Updater design and release runbook](docs/UPDATER.md).
