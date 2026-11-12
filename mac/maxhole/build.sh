#!/bin/bash
# Build MaxHole.driver (CoreAudio HAL plugin bundle) from src/maxhole.c.
# No Xcode needed — plain clang (see docs/mac-virtual-devices-plan.md V-2).
# Output: build/MaxHole.driver + build/MaxHole-<version>.pkg (install via:
#   sudo installer -pkg build/MaxHole-*.pkg -target / && sudo killall -9 coreaudiod)
set -euo pipefail
cd "$(dirname "$0")"

VERSION=0.1.0
BUNDLE_ID="io.onlyascii.maxhole"
OUT="build/MaxHole.driver"

rm -rf build
mkdir -p "$OUT/Contents/MacOS"
cp Info.plist "$OUT/Contents/Info.plist"

# Device shape per plan V-2: ONE plugin, TWO independent pipes.
#   MAX Mic: play Max's voice in (output)  -> meeting app reads it as mic (input)
#   MAX Out: meeting speaker goes in (out) -> agent records it (input)
clang -arch arm64 -mmacosx-version-min=13.0 -O2 -bundle \
	-framework CoreAudio -framework AudioToolbox -framework CoreFoundation -framework Accelerate \
	-DkDriver_Name='"MaxHole"' \
	-DkPlugIn_BundleID="\"$BUNDLE_ID\"" \
	-DkHas_Driver_Name_Format=false \
	-DkDevice_Name='"MAX Mic"' \
	-DkDevice2_Name='"MAX Out"' \
	-DkDevice_IsHidden=false \
	-DkDevice2_IsHidden=false \
	-DkDevice_HasInput=true \
	-DkDevice_HasOutput=true \
	-DkDevice2_HasInput=true \
	-DkDevice2_HasOutput=true \
	-DkManufacturer_Name='"OnlyASCII Ltd"' \
	-DkNumber_Of_Channels=2 \
	-DkLatency_Frame_Size=512 \
	-DkSampleRates='48000, 24000' \
	-o "$OUT/Contents/MacOS/MaxHole" \
	src/maxhole.c

# Ad-hoc sign — loads for personal machines with Team=None (V-2).
codesign --force --sign - "$OUT"

pkgbuild --root "$OUT" --identifier "$BUNDLE_ID" --version "$VERSION" \
	--install-location /Library/Audio/Plug-Ins/HAL "build/MaxHole-$VERSION.pkg"

echo "built: $OUT"
echo "pkg:   build/MaxHole-$VERSION.pkg"
