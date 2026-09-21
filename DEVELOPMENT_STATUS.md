# BWMonitor Development Status

## Implemented

- [x] Multiple VPS model and server editor
- [x] In-app SSH setup: host-key check and trust, key picker (BWMonitor's own key, keys in `~/.ssh`, SSH agent, key file, pasted key), key creation, public-key installation with the server password, one-step "Set Up Key Login", and a connection test with specific fixes
- [x] Keychain storage for KiwiVM API key, SSH password, and key passphrase; only the secrets the sign-in method needs are kept
- [x] Askpass helper: saved passwords and passphrases reach ssh through a private socket to the running app, for monitoring and the terminal alike
- [x] KiwiVM `getServiceInfo` client, traffic reset date, and `monthly_data_multiplier`
- [x] SSH host-key discovery (all key types), explicit trust, pinning, and changed-key blocking
- [x] One shared SSH connection per server (`ControlMaster`), backoff on network errors, and no retries after a rejected login
- [x] Linux metrics from `/proc`, `df`, `uptime`, `systemctl`, and `ps`
- [x] CPU, RAM, swap, disk, load, uptime, and network-rate dashboard
- [x] Traffic forecast from recent history
- [x] Native menu bar status and quick actions
- [x] WidgetKit small, medium, and large widgets through App Group snapshots
- [x] Multi-tab terminal: typing goes straight to the shell (input methods included), colors, line editing and wrapping, window titles, bracketed paste, and a hint for full-screen programs; "Open in Terminal" for those
- [x] SwiftData history and Swift Charts views
- [x] Traffic, sustained CPU, RAM, and disk notifications
- [x] Launch at login with `SMAppService`; optional automatic monitoring at launch
- [x] Light, dark, and system appearance
- [x] English and Simplified Chinese localization for the app, menu bar, alerts, errors, and Widget
- [x] Custom app icon (`BWMonitor.icns`) bundled with the app
- [x] Self-update from GitHub Releases (1.2): daily background check, a reminder in the sidebar and menu bar window, "Check for Updates…" in the app menu, and "Update Now", which downloads the DMG, verifies it, replaces the app in place, and reopens it

## Self-update (1.2)

`AppUpdateChecker` reads the latest release and picks the DMG for this Mac's architecture. The download must match the `SHA-256:` line of the release notes, so every release needs that line. `UpdateInstaller` then:

1. refuses app copies it cannot replace (running from a DMG, App Translocation, or a folder the user cannot write to);
2. mounts the DMG read-only with `nobrowse` in a temporary folder, so Spotlight never indexes it and Launchpad gets no extra copy;
3. checks the app inside: same bundle identifier, the released version, an intact signature, and, when the running app is signed by a team, the same team (so Keychain items stay readable without prompts);
4. copies it next to the old app (`itemReplacementDirectory`) and swaps the two with `renamex_np(RENAME_SWAP)`;
5. quits, waits for the process to exit, and opens the new version.

If a step fails, the DMG moves to Downloads and opens for a manual install.

For testing, `BWMONITOR_UPDATE_API` replaces the GitHub API URL (a `file://` JSON works, with `file://` asset URLs), `BWMONITOR_PRETEND_VERSION` replaces the running version, and `--debug-self-update` runs check and install without a window and prints the result.

## Fixed in 1.1

These kept 1.0 from ever showing live data:

- The pinned `known_hosts` path under "Application Support" was split at the space by ssh, so every connection failed host-key verification.
- The `/proc/net/dev` parser read the header line, so metrics collection always failed.
- `. /etc/os-release` made the metrics script fail on servers without that file.
- Host-key checks ran `ssh-keyscan` before every command and compared only the first key, whose type varies between scans.
- Encrypted keys could not be used for monitoring (`BatchMode=yes` without the agent), and the terminal typed saved secrets whenever output contained "password:".
- The terminal's ssh had no controlling terminal, so password and passphrase prompts failed and window size changes never reached the server.

Also: failed logins were retried every few seconds; `LC_ALL` was not exported; CPU counted I/O wait as busy; the first sample showed 0% CPU and no rates; KiwiVM data marked servers offline; widget timelines reloaded every sample; history was never pruned and was stored in the root of Application Support; the forecast treated any loaded range as one day; terminal sessions were lost when leaving the tab; the demo data contained a real server address.

## Security boundaries

- Secrets are never stored in UserDefaults, JSON, SwiftData, or App Group data.
- Only the app process reads the Keychain. The askpass socket answers only BWMonitor's own helper, started by the system `ssh`/`ssh-keygen`, started by the app.
- Host keys must be verified and trusted before SSH commands or terminal sessions run. A changed host key blocks the connection instead of silently replacing the saved key.
- Keys created by BWMonitor are files only the user can read, like keys in `~/.ssh`.
- Demo mode is offline and disables refresh, monitoring, and terminal connection actions.

## Verification performed

- `swift test`: 59 Swift Testing tests plus XCTest suites (Linux parsing with real `/proc/net/dev` output, SSH error classification from real ssh messages, host-key pinning, key inspection checked against `ssh-keygen`, the authorized_keys install script, the askpass socket refusing other processes, command lines, the terminal model including captured readline output, settings decoding of 1.0 `servers.json`, KiwiVM decoding).
- Live SSH tests (`BWMONITOR_TEST_SSH_*`) against a local `sshd` that emulates an Ubuntu server: trust, test, shared connection (first command about 40 ms, reused about 10 ms), metrics, and changed-host-key blocking.
- The app was driven end to end against that server with a renamed copy (`com.mujh.BWMonitor.devtest`): host-key trust, encrypted key with wrong and right passphrase, automatic monitoring after saving, services, the terminal (colors, CJK, emoji, editing, completion, history, Ctrl-C, wrapping, window title, full-screen hint), a passphrase typed into the terminal, a changed host key after "reinstalling", password sign-in refused by a key-only server, and the Terminal.app script.
- Xcode Debug and Release builds pass without warnings.
- Self-update (1.2), with signed test copies (`com.mujh.BWMonitor.devtest`, widget removed) and a local release JSON: a wrong checksum, a DMG with a different version, and an ad-hoc signed DMG were all refused and left the installed copy alone. A correct DMG replaced 1.1.9 with 1.2 in place, with a valid signature, and the app reopened by itself. No disk image stayed mounted, and no temporary files were left. Against the real v1.1.0 release it parsed the notes, matched the SHA-256, mounted the DMG, and refused it because the test copy's bundle identifier differs.

## Not verified

- Password sign-in and "Install on Server" against a server that accepts passwords (the local test server cannot check passwords without root). The code path is the one used for passphrases, and the install script was tested on its own.
- A live KiwiVM request (no API key was used).
- Widget/App Group and launch-at-login behavior, which require a signed build.
