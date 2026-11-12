#!/bin/bash
# MaxCam scripted build (no Xcode GUI): xcodegen -> xcodebuild -> manual
# system-extension embed -> re-sign outer app -> install to /Applications.
# Requires: brew xcodegen, an "Apple Development" identity (team E6W58DTJJ8),
# network for -allowProvisioningUpdates.
set -euo pipefail
cd "$(dirname "$0")"

IDENTITY="Apple Development: Panagiotis Xynos (E6W58DTJJ8)"

xcodegen generate
xcodebuild -project MaxCamHost.xcodeproj -scheme MaxCamHost -configuration Release \
  -derivedDataPath build -allowProvisioningUpdates build

REL=build/Build/Products/Release
APP="$REL/MaxCamHost.app"
APPEX="$REL/MaxCamExtension.appex"
[ -d "$APP" ] && [ -d "$APPEX" ] || { echo "build products missing"; exit 1; }

# system extensions live in Contents/Library/SystemExtensions (NOT PlugIns)
rm -rf "$APP/Contents/PlugIns/MaxCamExtension.appex"
mkdir -p "$APP/Contents/Library/SystemExtensions"
cp -R "$APPEX" "$APP/Contents/Library/SystemExtensions/"

# re-sign the OUTER app only (appex keeps its own signature); preserve the
# automatically-provisioned entitlements by extracting them first
codesign -d --entitlements :- "$APP" > /tmp/maxcamhost-ent.plist 2>/dev/null
codesign --force --options runtime --sign "$IDENTITY" --entitlements /tmp/maxcamhost-ent.plist "$APP"
codesign --verify --verbose=2 "$APP"

echo "== installing to /Applications =="
rm -rf /Applications/MaxCamHost.app
ditto "$APP" /Applications/MaxCamHost.app
echo "NOW (owner, in a terminal):  /Applications/MaxCamHost.app/Contents/MacOS/MaxCamHost --activate"
echo "then approve: System Settings > General > Login Items & Extensions > Camera Extensions"
echo "verify:       systemextensionsctl list"
