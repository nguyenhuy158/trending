#!/bin/bash
set -e
cd "$(dirname "$0")"
APP="Trending.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>Trending</string>
  <key>CFBundleExecutable</key><string>Trending</string>
  <key>CFBundleIdentifier</key><string>local.trending</string>
  <key>CFBundleVersion</key><string>1.0</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
</dict></plist>
PLIST
[ -f AppIcon.icns ] || iconutil -c icns AppIcon.iconset -o AppIcon.icns
cp AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
swiftc -O -parse-as-library App.swift Store.swift AI.swift -o "$APP/Contents/MacOS/Trending" -framework Cocoa -framework SwiftUI
codesign --force --sign - "$APP"
echo "Built $APP — open $APP"
