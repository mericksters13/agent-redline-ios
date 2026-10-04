#!/bin/zsh
# Builds "Agentic Debugging.app", the hub as a menu bar app, from this package and signs it for
# local use. Installs it in ~/Applications unless a destination folder is given.
set -euo pipefail
cd "$(dirname "$0")/.."
destination="${1:-$HOME/Applications}"
swift build -c release --product agentic-debugging
binary="$(swift build -c release --show-bin-path)/agentic-debugging"
app="$destination/Agentic Debugging.app"
staging="$(mktemp -d)/Agentic Debugging.app"
mkdir -p "$staging/Contents/MacOS" "$staging/Contents/Resources"
cp "$binary" "$staging/Contents/MacOS/agentic-debugging"
iconset="$(mktemp -d)/AppIcon.iconset"
swift scripts/hub-app-icon.swift "$iconset"
iconutil --convert icns --output "$staging/Contents/Resources/AppIcon.icns" "$iconset"
cat > "$staging/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>agentic-debugging</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundleIdentifier</key><string>com.iosagenticdebuggingkit.hub</string>
    <key>CFBundleName</key><string>Agentic Debugging</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.1</string>
    <key>LSMinimumSystemVersion</key><string>15.0</string>
    <key>LSUIElement</key><true/>
</dict>
</plist>
PLIST
codesign --force --sign - "$staging"
mkdir -p "$destination"
rm -rf "$app"
mv "$staging" "$app"
echo "Built $app"
