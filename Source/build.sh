#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"
APP="$ROOT/SwitchDrop.app"
export MACOSX_DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET:-13.0}"
./Source/build-deps.sh
MTP="$ROOT/.build/deps-$MACOSX_DEPLOYMENT_TARGET"
USB="$MTP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Frameworks" "$APP/Contents/Resources"
clang -O2 -Wall -Wextra -Werror -mmacosx-version-min="$MACOSX_DEPLOYMENT_TARGET" -I"$MTP/include" Source/mtp-helper.c -L"$MTP/lib" -lmtp -o "$APP/Contents/MacOS/mtp-helper"
swiftc -O -swift-version 5 -target "arm64-apple-macosx$MACOSX_DEPLOYMENT_TARGET" Source/main.swift Source/Browser.swift Source/Localization.swift -o "$APP/Contents/MacOS/SwitchDrop" -framework Cocoa -framework SwiftUI -framework UniformTypeIdentifiers
cp "$MTP/lib/libmtp.9.dylib" "$APP/Contents/Frameworks/"
cp "$USB/lib/libusb-1.0.0.dylib" "$APP/Contents/Frameworks/"
chmod u+w "$APP/Contents/Frameworks/"*.dylib
install_name_tool -change "$MTP/lib/libmtp.9.dylib" '@executable_path/../Frameworks/libmtp.9.dylib' "$APP/Contents/MacOS/mtp-helper"
install_name_tool -id '@rpath/libmtp.9.dylib' -change "$USB/lib/libusb-1.0.0.dylib" '@loader_path/libusb-1.0.0.dylib' "$APP/Contents/Frameworks/libmtp.9.dylib"
install_name_tool -id '@rpath/libusb-1.0.0.dylib' "$APP/Contents/Frameworks/libusb-1.0.0.dylib"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleName</key><string>SwitchDrop</string>
<key>CFBundleDisplayName</key><string>SwitchDrop</string>
<key>CFBundleIdentifier</key><string>local.jakoms.switchdrop</string>
<key>CFBundleExecutable</key><string>SwitchDrop</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>2.0.0</string>
<key>CFBundleVersion</key><string>3</string>
<key>LSMinimumSystemVersion</key><string>$MACOSX_DEPLOYMENT_TARGET</string>
<key>NSHighResolutionCapable</key><true/>
<key>NSHumanReadableCopyright</key><string>SwitchDrop · libmtp / libusb: LGPL 2.1</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>CFBundleDocumentTypes</key><array><dict>
<key>CFBundleTypeName</key><string>Switch game package</string>
<key>CFBundleTypeExtensions</key><array><string>nsp</string><string>nsz</string><string>xci</string><string>xcz</string></array>
<key>CFBundleTypeRole</key><string>Viewer</string>
<key>LSHandlerRank</key><string>Alternate</string>
</dict></array>
</dict></plist>
PLIST
if [ -f Source/AppIcon.icns ]; then cp Source/AppIcon.icns "$APP/Contents/Resources/"; fi
if [ -d Licenses ]; then cp -R Licenses "$APP/Contents/Resources/"; fi
codesign --force --sign - "$APP/Contents/Frameworks/libusb-1.0.0.dylib"
codesign --force --sign - "$APP/Contents/Frameworks/libmtp.9.dylib"
codesign --force --sign - "$APP/Contents/MacOS/mtp-helper"
codesign --force --sign - "$APP"
codesign --verify --deep --strict "$APP"
"$APP/Contents/MacOS/mtp-helper" --self-test
"$APP/Contents/MacOS/SwitchDrop" --self-test
