# Security policy

## Supported version

Security fixes target the latest release and the `main` branch.

## Reporting a vulnerability

Do not open a public issue for a vulnerability or exposed secret. Use GitHub's private vulnerability reporting feature on this repository. Include the affected version, reproduction steps, impact, and any suggested mitigation.

## Security boundaries

- Memory Widget is a local desktop application, not a sandbox.
- Process inspection runs with the current user's privileges.
- Camera, microphone, and screen signals depend on explicit macOS privacy controls.
- The MCP server is local stdio only and inherits the permissions of the agent that launches it.
- Tool annotations are descriptive hints; agents must still apply their own approval and sandbox policies.
- Raw evidence is sensitive even though it is local. Files are stored in the user's Application Support directory and removed after seven days.

## Build integrity

Release workflows build from tagged source with ad-hoc signing, create an Apple Silicon ZIP, and publish a SHA-256 checksum. Repository CI compiles the app, verifies the bundle signature, and executes both modern and legacy MCP protocol tests. Release archives are not Apple-notarized unless a maintainer separately introduces a protected Developer ID and notarization workflow.
