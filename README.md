# XM4 Pilot

A native SwiftUI menu-bar controller for Sony WH-1000XM4 headphones on macOS.

## Features

- Off / Noise Cancelling / Ambient, ambient level (1–20) and Focus on Voice
- Battery level and charging state in the menu bar
- Focus, Office and Aware one-click presets
- Sony EQ presets plus a live Clear Bass + 5-band custom EQ with saved personal presets
- Global `⌥⌘A` shortcut to toggle ANC / Ambient
- Launch at login, automatic reconnect with backoff, copyable diagnostics

## Install

1. Download `XM4-Pilot-<version>.dmg` from [Releases](../../releases).
2. Open it and drag **XM4 Pilot** into **Applications**.
3. The app isn't notarized by Apple, so the first launch is blocked. Open it once, then go to
   **System Settings → Privacy & Security** and click **Open Anyway**.
   (Or run `xattr -dr com.apple.quarantine "/Applications/XM4 Pilot.app"`.)
4. Allow Bluetooth access when asked. The app lives in the menu bar.

## Build

Requires Xcode (macOS 14+ target).

```sh
scripts/build-app.sh            # universal release build → build/XM4 Pilot.app
scripts/make-dmg.sh             # → build/XM4-Pilot-<version>.dmg
open "build/XM4 Pilot.app"
swift test                      # protocol + settings tests
```

The headphones must be paired and connected. Only one process can own Sony's control channel, so close Sony Headphones Connect on your phone if the link reports busy.
