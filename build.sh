#!/bin/sh
# Compile l'app « WiiU Pro.app » et l'outil wiiu-pro-dsu avec les Command Line Tools
# (Xcode non requis). Signature ad hoc.
set -e
cd "$(dirname "$0")"
mkdir -p build

# Outil en ligne de commande
swiftc -O -swift-version 5 \
    -o build/wiiu-pro-dsu Sources/Core/*.swift Sources/CLI/*.swift \
    -framework IOBluetooth \
    -Xlinker -sectcreate -Xlinker __TEXT -Xlinker __info_plist -Xlinker Info.plist
codesign --force --sign - --identifier com.wiiupromac.dsu build/wiiu-pro-dsu

# Application graphique
APP="build/WiiU Pro.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp AppInfo.plist "$APP/Contents/Info.plist"
swiftc -O -swift-version 5 -parse-as-library \
    -o "$APP/Contents/MacOS/WiiUPro" Sources/Core/*.swift Sources/App/*.swift \
    -framework IOBluetooth -framework SwiftUI -framework AppKit
codesign --force --sign - "$APP"

echo "OK : build/wiiu-pro-dsu et $APP"
