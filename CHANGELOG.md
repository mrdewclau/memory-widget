# Changelog

All notable changes are documented here.

## 2.2.0 - 2026-08-11

- Added secure in-app updates powered by Sparkle 2.9.5.
- Added automatic daily update discovery and manual checks in desktop and menu-bar modes.
- Added Ed25519 verification for both the signed update feed and archive before extraction.
- Added lossless app-bundle replacement that preserves RAM history, Context Observatory evidence, MCP configuration, preferences, and window placement.
- Added GitHub release automation for signed appcasts and portable archive checksums.

## 2.1.1 - 2026-08-11

- Made release checksums portable so downloaded archives verify from any directory.
- Updated the official GitHub Actions dependencies used by CI, CodeQL, and release packaging.

## 2.1.0 - 2026-08-11

- Added complete physical-RAM composition and available-memory headroom.
- Added grouped app footprints with expandable provenance, process roles, icons, and plain-language explanations.
- Added responsive full, compact, and menu-bar modes.
- Added a locally persisted RAM timeline and synchronized context ribbon.
- Added Context Observatory with bounded camera, microphone, screen, input, CPU, and audio-app signals.
- Added permission circuit breakers that prevent repeated macOS Settings prompts.
- Added a local stdio MCP server supporting MCP 2026-07-28 and 2025-11-25.
- Added deterministic MCP protocol tests, release packaging, privacy documentation, and security policy.
