#!/bin/bash
# MaxCam scripted build (no Xcode GUI).
# xcodegen cannot emit product-type system-extension; we sed the generated
# pbxproj so Xcode embeds the appex into Contents/Library/SystemExtensions
# ITSELF and provisions per-id profiles (host io.onlyascii.maxcam, ext
# io.onlyascii.maxcam.extension — ext id MUST be prefixed by host id,
# verified by build error otherwise).
# Requires: brew xcodegen, Apple ID (team R2XM78R4TE) signed into Xcode,
# network for -allowProvisioningUpdates.
set -euo pipefail
cd "$(dirname "$0")"

IDENTITY="Apple Development: Panagiotis Xynos (E6W58DTJJ8)"

xcodegen generate
# (xcodegen 2.46 natively supports type: system-extension — produces the
# template's exact structure: wrapper.system-extension product + Embed
# System Extensions copy phase into $(SYSTEM_EXTENSIONS_FOLDER_PATH))

if [ "${NO_PROFILE:-0}" = "1" ]; then
  # EXPERIMENT PATH — dead end for the HOST (system-extension.install without
  # a profile = SIGKILL at exec, proven 2026-11-12). Kept for ext-only probes.
  xcodebuild -project MaxCamHost.xcodeproj -scheme MaxCamHost -configuration Release \
    -derivedDataPath build CODE_SIGNING_ALLOWED=NO build
else
  xcodebuild -project MaxCamHost.xcodeproj -scheme MaxCamHost -configuration Release \
    -derivedDataPath build -allowProvisioningUpdates build
fi

REL=build/Build/Products/Release
APP="$REL/MaxCamHost.app"
# system-extension product type builds MaxCamExtension.systemextension (NOT
# .appex); xcodegen's embed lands it in PlugIns but the activation service
# scans Contents/Library/SystemExtensions — relocate it (this was the whole
# 'Code=4 Extension not found' story).
SE="$APP/Contents/Library/SystemExtensions/MaxCamExtension.systemextension"
if [ ! -d "$SE" ] && [ -d "$APP/Contents/PlugIns/MaxCamExtension.systemextension" ]; then
  mkdir -p "$APP/Contents/Library/SystemExtensions"
  mv "$APP/Contents/PlugIns/MaxCamExtension.systemextension" "$SE"
fi
[ -d "$SE" ] || { echo "systemextension not found after build"; exit 1; }

if [ "${NO_PROFILE:-0}" = "1" ]; then
  sed 's|\$(TeamIdentifierPrefix)|R2XM78R4TE.|g' ext.entitlements  > /tmp/maxcam-ext-ent.plist
  sed 's|\$(TeamIdentifierPrefix)|R2XM78R4TE.|g' host.entitlements > /tmp/maxcam-host-ent.plist
  codesign --force --options runtime --sign "$IDENTITY" --entitlements /tmp/maxcam-ext-ent.plist "$SE"
  codesign --force --options runtime --sign "$IDENTITY" --entitlements /tmp/maxcam-host-ent.plist "$APP"
else
  # mv broke the outer seal: re-sign preserving the provisioned entitlements
  codesign -d --entitlements :- "$APP" > /tmp/maxcamhost-ent.plist 2>/dev/null
  codesign --force --options runtime --sign "$IDENTITY" --entitlements /tmp/maxcamhost-ent.plist "$APP"
fi
codesign --verify --verbose=1 "$APP"

echo "== installing to /Applications =="
rm -rf /Applications/MaxCamHost.app
ditto "$APP" /Applications/MaxCamHost.app
/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister -f /Applications/MaxCamHost.app
echo "NOW (owner, in a terminal):  /Applications/MaxCamHost.app/Contents/MacOS/MaxCamHost --activate"
echo "then approve: System Settings > General > Login Items & Extensions > Camera Extensions"
echo "verify:       systemextensionsctl list"
