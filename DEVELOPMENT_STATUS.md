# BWMonitor Development Status

## First-release implementation

- [x] Multiple VPS model and server editor
- [x] Keychain storage for KiwiVM API key, SSH password, and key passphrase
- [x] KiwiVM `getServiceInfo` client and traffic reset date
- [x] SSH host-key discovery, explicit trust, pinning, and changed-key blocking
- [x] Linux metrics from `/proc`, `df`, `uptime`, `systemctl`, and `ps`
- [x] CPU, RAM, swap, disk, load, uptime, and network-rate dashboard
- [x] Traffic forecast from recent history
- [x] Native menu bar status and quick actions
- [x] WidgetKit small, medium, and large widgets through App Group snapshots
- [x] Multi-tab pseudo-terminal using the system OpenSSH client
- [x] ANSI foreground colors, copy/select, paste/input, scrollback, history, resize, and fullscreen-window support
- [x] SwiftData history and Swift Charts views
- [x] Traffic, sustained CPU, RAM, and disk notifications
- [x] Launch at login with `SMAppService`
- [x] Light, dark, and system appearance
- [x] English and Simplified Chinese localization for the app, menu bar, alerts, errors, and Widget
- [x] Custom app icon (`BWMonitor.icns`) bundled with the app
- [x] GitHub Releases update channel with launch auto-check and Settings manual check

## Security boundaries

- Secrets are never stored in UserDefaults, JSON, SwiftData, or App Group data.
- Background monitoring uses a private key or SSH agent. A stored password is supplied only to an interactive pseudo-terminal prompt.
- Host keys must be verified and trusted before SSH commands or terminal sessions run.
- A changed host key blocks the connection instead of silently replacing the saved key.
- Demo mode is offline and disables refresh, monitoring, and terminal connection actions.

## Verification performed

- `swift test`: 3 tests passed (Linux parser/rate calculation and traffic forecasting).
- Xcode Debug build: passed for the app and Widget extension.
- Xcode static analysis: passed.
- Xcode Release build: passed for the app and Widget extension.
- The built app was launched with `--demo` and inspected in light and dark appearances.
- Simplified Chinese was forced at launch and visually checked on the dashboard, network chart, settings, and server editor, including dynamic units and long field labels.
- Signed dev build passes `codesign --verify --deep --strict` and launches in `--demo` mode.

## Requires user credentials or signing

- A live KiwiVM request and live SSH session were not attempted because no credentials were supplied.
- Widget/App Group and launch-at-login behavior require the signed build (`outputs/BWMonitor-signed-dev.app`, Apple Development team 6UBGLWDQ4P); install it to /Applications and add the widget manually to verify on-desktop display.
- The unsigned deliverable is not notarized; neither build is a public release.
- Confirm the first SSH fingerprint through KiwiVM or the VPS provider before pressing **Trust**.
