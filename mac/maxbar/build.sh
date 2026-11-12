#!/bin/sh
# Build MAXBar.app (menu-bar status item) with plain swiftc — CLT-only machine.
set -e
cd "$(dirname "$0")"
APP=build/MAXBar.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
swiftc -O -target arm64-apple-macos13.0 main.swift \
    -o "$APP/Contents/MacOS/maxbar" \
    -framework AppKit -framework CoreAudio -framework CoreMediaIO
sed "s/@VERSION@/$(date -u +%Y%m%d)/" Info.plist > "$APP/Contents/Info.plist"
codesign --force --sign - "$APP"
echo "built $APP"
echo "install:  ditto \"$APP\" ~/Applications/MAXBar.app && open ~/Applications/MAXBar.app"
