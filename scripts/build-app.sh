#!/bin/bash
# Builds build/XM4 Pilot.app with swiftc directly, so only the Command Line Tools are needed.
# Usage: scripts/build-app.sh [debug|release]
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${1:-release}"
APP="build/XM4 Pilot.app"
FLAGS=(-swift-version 6 -target "$(uname -m)-apple-macos14.0" -D MENU_BAR_APP -parse-as-library)
if [[ "$CONFIG" == "debug" ]]; then FLAGS+=(-Onone -g -D DEBUG); else FLAGS+=(-O); fi

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
xcrun swiftc "${FLAGS[@]}" Sources/XM4Pilot/*.swift -o "$APP/Contents/MacOS/XM4Pilot"
cp Support/Info.plist "$APP/Contents/Info.plist"
codesign --force --sign - --entitlements Support/XM4Pilot.entitlements "$APP"
echo "Built $APP"
