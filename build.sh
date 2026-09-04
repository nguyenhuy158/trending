#!/bin/bash
set -e
cd "$(dirname "$0")"
APP="Trending.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
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
</dict></plist>
PLIST
swiftc -O -parse-as-library App.swift -o "$APP/Contents/MacOS/Trending" -framework Cocoa -framework SwiftUI
codesign --force --sign - "$APP"
echo "Built $APP — open $APP"
