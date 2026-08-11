# Secure updater

Memory Widget 2.2.0 introduces a deliberately narrow update path powered by Sparkle 2.9.5.

## User flow

1. Sparkle checks the stable feed once per day, or immediately when the circular-arrow control is clicked.
2. A signed appcast describes the newest compatible Apple Silicon release.
3. When a newer build exists, Sparkle shows its release notes and asks the user before continuing.
4. Sparkle downloads the tag-specific ZIP over HTTPS, verifies its Ed25519 signature before extraction, stages it, and replaces the application bundle.
5. Sparkle relaunches the new app only through its visible update flow.

Background discovery is enabled. Automatic installation is disabled. Sparkle system profiling is disabled.

## What an update can change

The update contains one object: `Memory Widget.app`. It does not package or target persistent state.

| Preserved state | Location |
| --- | --- |
| RAM history and MCP live state | `~/Library/Application Support/Memory Widget/` |
| Context timeline and raw evidence | `~/Library/Application Support/Memory Widget/Context Observatory/` |
| Window placement, mode, capture decisions, and preferences | macOS UserDefaults for `local.memory-widget` |
| macOS privacy grants | macOS Transparency, Consent, and Control database |

No data migration is needed for 2.2.0. If a future release changes a persistent schema, it must read the old form, write the new form atomically, and leave a recoverable backup until the new form is validated.

## Trust chain

```text
embedded Ed25519 public key
        ├── authenticates appcast.xml
        └── authenticates release ZIP before extraction

HTTPS GitHub release transport
        └── provides transport confidentiality and availability

macOS bundle signature
        └── verifies the staged bundle is internally intact
```

The stable app reads `https://github.com/mrdewclau/memory-widget/releases/latest/download/appcast.xml`. Each appcast points to an immutable, tag-specific archive URL. `SURequireSignedFeed` and `SUVerifyUpdateBeforeExtraction` are enabled. A modified feed or archive fails closed.

Current public releases are ad-hoc signed and not Apple-notarized. Sparkle's Ed25519 signature authenticates the project's releases, but it is not a substitute for a Developer ID identity. A future Developer ID migration must retain the Sparkle key so already-installed builds can authenticate the transition.

## Key custody

- Public key: embedded in `Memory Widget.app/Contents/Info.plist`.
- Local private key: macOS Keychain account `memory-widget`.
- Automation private key: protected GitHub Actions secret `SPARKLE_PRIVATE_KEY`.
- The private key must never be committed, logged, uploaded as a release asset, or supplied as a command-line argument.

Loss of the private key prevents installed builds from trusting future updates. Suspected key compromise requires suspending releases and shipping a manually installed trust transition; silently replacing the embedded key is not possible.

## Release runbook

1. Increment `CFBundleShortVersionString` and the monotonically increasing `CFBundleVersion` in `build_app.sh`.
2. Add a matching `CHANGELOG.md` section.
3. Run `./build_app.sh`, `./test_mcp.sh`, and `./scripts/test_updater.sh`.
4. Merge the change through a reviewed, green pull request.
5. Tag the merge commit `vX.Y.Z` and push that tag.
6. The release workflow validates the tag, downloads checksum-pinned Sparkle tools, builds and packages the app, signs the archive and feed, performs positive and tamper tests, and publishes all `dist/` artifacts.
7. Download the published ZIP and checksum into a clean directory and verify the checksum, bundle signature, version, feed discovery, and installation from the previous release.
8. Confirm the sentinel history/preferences created before updating still exist after relaunch.

The first updater-capable release is a one-time bootstrap: 2.1.1 users must manually install 2.2.0. Every later compatible release can use the in-app path.

## Failure and recovery

- Unreachable feed: the running app remains unchanged and can be checked later.
- Invalid feed signature: the feed is rejected; no archive is selected.
- Invalid archive signature or checksum: extraction/installation is rejected.
- Interrupted download: the installed app and persistent state remain untouched.
- Relaunch failure: the installed bundle can still be opened manually; persistent data is outside the bundle.
- Bad but correctly signed release: reinstall a prior ZIP manually, or publish a higher build that fixes the defect. User data should not be rolled back with the app.
