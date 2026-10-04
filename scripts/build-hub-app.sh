#!/bin/zsh
# Builds "Redline.app", the hub as a menu bar app, from this package and signs it for
# local use. Installs it in ~/Applications unless a destination folder is given.
set -euo pipefail
cd "$(dirname "$0")/.."
destination="${1:-$HOME/Applications}"
swift build -c release --product redline
binary="$(swift build -c release --show-bin-path)/redline"
app="$destination/Redline.app"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
staging="$work/Redline.app"
mkdir -p "$staging/Contents/MacOS" "$staging/Contents/Resources"
cp "$binary" "$staging/Contents/MacOS/redline"
iconset="$work/AppIcon.iconset"
swift scripts/hub-app-icon.swift "$iconset"
iconutil --convert icns --output "$staging/Contents/Resources/AppIcon.icns" "$iconset"
cat > "$staging/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>redline</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundleIdentifier</key><string>com.agentredline.hub</string>
    <key>CFBundleName</key><string>Redline</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.1</string>
    <key>LSMinimumSystemVersion</key><string>15.0</string>
    <key>LSUIElement</key><true/>
</dict>
</plist>
PLIST
# Signed with the Mac's Apple Development certificate when there is one, so macOS remembers what
# the user allowed the app to open, such as chat folders in Documents, across rebuilds. An ad hoc
# signature is new with every build, so macOS would ask again each time. Signing with the
# certificate fails over SSH or with the keychain locked; then it signs ad hoc.
identity="$(security find-identity -v -p codesigning | awk '/"Apple Development/ { print $2; exit }')"
if [[ -n "$identity" ]] && codesign --force --sign "$identity" "$staging"; then
    echo "Signed with the Apple Development certificate $identity"
else
    [[ -z "$identity" ]] || echo "Signing with the Apple Development certificate failed"
    codesign --force --sign - "$staging"
    echo "Signed ad hoc"
fi
mkdir -p "$destination"
# A running copy is stopped first and opened again after: macOS may not match a running app to a
# bundle replaced under it, and ask for permissions again. A stop signal, not an AppleScript quit,
# which would need its own permission.
# pgrep and pkill take a regular expression, so the path's special characters are escaped.
processes="$(printf '%s' "$app/Contents/MacOS/" | sed 's/[][\.*^$+?(){}|]/\\&/g')"
running=false
if pkill -TERM -f "$processes" 2>/dev/null; then
    running=true
    for _ in 1 2 3 4 5 6 7 8 9 10; do pgrep -f "$processes" >/dev/null || break; sleep 0.3; done
fi
rm -rf "$app"
mv "$staging" "$app"
if $running; then open -g "$app"; fi
echo "Built $app"
