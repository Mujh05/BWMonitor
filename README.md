# BWMonitor

BWMonitor is a native macOS VPS monitor and manager. The first release focuses on
BandwagonHost/KiwiVM traffic data plus live Linux metrics collected over the
system OpenSSH client.

Project home: https://github.com/Mujh05/BWMonitor

## Updates

BWMonitor checks GitHub Releases for new builds: automatically at launch (at
most once a week, silently unless an update is found) and manually from
**Settings > About > Software Update**.

## What is implemented

- Multiple-server configuration with non-sensitive data stored locally
- KiwiVM `getServiceInfo` integration with a three-minute refresh policy
- Verified SSH host keys and strict per-app `known_hosts`
- CPU, memory, swap, disk, load, uptime, and network-rate collection
- Native SwiftUI dashboard, history charts, services/process views, and terminal
- Menu bar status, WidgetKit extension, notifications, and launch at login
- Keychain storage for API keys, passwords, and private-key passphrases
- English and Simplified Chinese UI that follows the macOS app language

The app never embeds API keys or passwords. Background monitoring uses a private
key or the user's SSH agent; password authentication is handled only inside the
interactive terminal.

## Build

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcodebuild -project BWMonitor.xcodeproj -scheme BWMonitor \
  -configuration Debug -derivedDataPath .build/DerivedData \
  CODE_SIGNING_ALLOWED=NO build
```

Core tests can also run independently:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test
```

Use the `--demo` launch argument to preview the interface without contacting a
server. App Group and launch-at-login behavior require normal local signing.

## Language

BWMonitor follows the language selected by macOS. To choose a language only for
BWMonitor, open **System Settings > General > Language & Region > Applications**,
add BWMonitor, then select English or Simplified Chinese.
