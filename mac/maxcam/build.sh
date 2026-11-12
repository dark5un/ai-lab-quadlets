#!/bin/bash
# MaxCam scripted build (no Xcode GUI): xcodegen -> xcodebuild -> manual
# system-extension embed -> re-sign outer app -> install to /Applications.
# Requires: brew xcodegen, an "Apple Development" identity (team E6W58DTJJ8),
# network for -allowProvisioningUpdates.
set -euo pipefail
cd "$(dirname "$0")"

IDENTITY="Apple Development: Panagiotis Xynos (E6W58DTJJ8)"

xcodegen generate
if [ "${NO_PROFILE:-0}" = "1" ]; then
  # Path B: compile without any signing (no account/profile session needed);
  # we hand-sign below with the existing Apple Development identity.
  xcodebuild -project MaxCamHost.xcodeproj -scheme MaxCamHost -configuration Release \
    -derivedDataPath build CODE_SIGNING_ALLOWED=NO build
else
  xcodebuild -project MaxCamHost.xcodeproj -scheme MaxCamHost -configuration Release \
    -derivedDataPath build -allowProvisioningUpdates build
fi

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
if [ "${NO_PROFILE:-0}" = "1" ]; then
  # Path B: sign BOTH by hand, entitlements straight from our files
  # (hardened runtime on; free-team/no-profile activation = the experiment).
  # codesign does NOT expand Xcode macros — pre-substitute the team prefix.
  sed 's|\$(TeamIdentifierPrefix)|R2XM78R4TE.|g' ext.entitlements  > /tmp/maxcam-ext-ent.plist
  sed 's|\$(TeamIdentifierPrefix)|R2XM78R4TE.|g' host.entitlements > /tmp/maxcam-host-ent.plist
  codesign --force --options runtime --sign "$IDENTITY" --entitlements /tmp/maxcam-ext-ent.plist \
    "$APP/Contents/Library/SystemExtensions/MaxCamExtension.appex"
  codesign --force --options runtime --sign "$IDENTITY" --entitlements /tmp/maxcam-host-ent.plist "$APP"
else
  codesign -d --entitlements :- "$APP" > /tmp/maxcamhost-ent.plist 2>/dev/null
  codesign --force --options runtime --sign "$IDENTITY" --entitlements /tmp/maxcamhost-ent.plist "$APP"
fi
codesign --verify --verbose=2 "$APP"

echo "== installing to /Applications =="
rm -rf /Applications/MaxCamHost.app
ditto "$APP" /Applications/MaxCamHost.app
echo "NOW (owner, in a terminal):  /Applications/MaxCamHost.app/Contents/MacOS/MaxCamHost --activate"
echo "then approve: System Settings > General > Login Items & Extensions > Camera Extensions"
echo "verify:       systemextensionsctl list"
