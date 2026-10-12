#!/bin/bash
# Builds build/XM4 Pilot.app with swiftc directly.
# Usage: scripts/build-app.sh [debug|release]
# Release builds are universal (Apple Silicon + Intel); debug builds target this Mac only.
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${1:-release}"
APP="build/XM4 Pilot.app"
FLAGS=(-swift-version 6 -D MENU_BAR_APP -parse-as-library)
if [[ "$CONFIG" == "debug" ]]; then
    FLAGS+=(-Onone -g -D DEBUG)
    ARCHS=("$(uname -m)")
else
    FLAGS+=(-O)
    ARCHS=(arm64 x86_64)
fi

rm -rf "$APP" build/obj
mkdir -p "$APP/Contents/MacOS" build/obj
SLICES=()
for arch in "${ARCHS[@]}"; do
    xcrun swiftc "${FLAGS[@]}" -target "$arch-apple-macos14.0" Sources/XM4Pilot/*.swift -o "build/obj/XM4Pilot-$arch"
    SLICES+=("build/obj/XM4Pilot-$arch")
done
lipo -create "${SLICES[@]}" -output "$APP/Contents/MacOS/XM4Pilot"
cp Support/Info.plist "$APP/Contents/Info.plist"
codesign --force --sign - --entitlements Support/XM4Pilot.entitlements "$APP"
echo "Built $APP ($(lipo -archs "$APP/Contents/MacOS/XM4Pilot"))"
