#!/bin/bash
# Builds a release app and packages it as build/XM4-Pilot-<version>.dmg
# with an Applications shortcut for drag-to-install.
set -euo pipefail
cd "$(dirname "$0")/.."

scripts/build-app.sh release
VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" Support/Info.plist)
DMG="build/XM4-Pilot-$VERSION.dmg"
STAGING=build/dmg

rm -rf "$STAGING" "$DMG"
mkdir -p "$STAGING"
cp -R "build/XM4 Pilot.app" "$STAGING/"
ln -s /Applications "$STAGING/Applications"
hdiutil create -volname "XM4 Pilot" -srcfolder "$STAGING" -fs HFS+ -format UDZO -ov "$DMG" >/dev/null
rm -rf "$STAGING"
echo "Created $DMG"
