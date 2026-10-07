# XM4 Pilot

A native SwiftUI menu-bar controller for Sony WH-1000XM4 headphones on macOS.
Ported from [XM5 Control](https://github.com/Maadlou/xm5-control-macos) (MIT), with the protocol layer rewritten for the XM4's MDR v1 command set.

## Features

- Off / Noise Cancelling / Ambient, ambient level (1–20) and Focus on Voice
- Battery level and charging state in the menu bar
- Focus, Office and Aware one-click presets
- Sony EQ presets plus a live Clear Bass + 5-band custom EQ with saved personal presets
- Global `⌥⌘A` shortcut to toggle ANC / Ambient
- Launch at login, automatic reconnect with backoff, copyable diagnostics

## Build

Requires Xcode (macOS 14+ target).

```sh
scripts/build-app.sh            # release build → build/XM4 Pilot.app
open "build/XM4 Pilot.app"
swift test                      # protocol + settings tests
```

The headphones must be paired and connected. Only one process can own Sony's control channel, so close Sony Headphones Connect on your phone if the link reports busy.
