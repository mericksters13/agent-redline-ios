#!/bin/zsh
# Builds "Redline.app", the hub as a menu bar app, from this package and signs it for
# local use. Installs it in ~/Applications unless a destination folder is given.
set -euo pipefail
cd "$(dirname "$0")/.."
destination="${1:-$HOME/Applications}"
# Absolute, so Launch Services registers and opens the app by its full path.
mkdir -p "$destination"
destination="$(cd "$destination" && pwd -P)"
swift build -c release --product redline
binary="$(swift build -c release --show-bin-path)/redline"
app="$destination/Redline.app"
staging="$(mktemp -d)/Redline.app"
mkdir -p "$staging/Contents/MacOS" "$staging/Contents/Resources"
cp "$binary" "$staging/Contents/MacOS/redline"
iconset="$(mktemp -d)/AppIcon.iconset"
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
    <key>NSLocalNetworkUsageDescription</key><string>Redline takes the reports your apps send from iPhones on this network, and notices when a paired iPhone wakes.</string>
    <key>NSBonjourServices</key><array><string>_remotepairing._tcp</string></array>
</dict>
</plist>
PLIST
# Signed with the Mac's Apple Development certificate when there is one, so macOS remembers what
# the user allowed the app to open, such as chat folders in Documents, across rebuilds. An ad hoc
# signature is new with every build, so macOS would ask again each time.
identity="$(security find-identity -v -p codesigning | awk '/"Apple Development/ { print $2; exit }')"
codesign --force --sign "${identity:--}" "$staging"
# A running copy is stopped first and opened again after: macOS may not match a running app to a
# bundle replaced under it, and ask for permissions again. A stop signal, not an AppleScript quit,
# which would need its own permission. The bundle is replaced only once the old copy has exited,
# so the open below starts the new one. Asked to stop, the app first lets the reports it is
# handing over reach their chats, which can take minutes. One that hasn't exited after about 15
# seconds is killed only when it isn't handing a report over: killed mid hand-over, the next hub
# would hand the report over again while the chat the old one started still has it.
# Any installed copy is matched, not only the one in this destination: the copy running from an
# earlier destination holds the hub's lock, so the new one could not start while it runs.
running=false
stop_running_copies() {
    local name="$1" inbox="$2"
    local copies="/$name.app/Contents/MacOS/"
    pkill -TERM -f "$copies" 2>/dev/null || return 0
    running=true
    for _ in {1..50}; do pgrep -f "$copies" >/dev/null || break; sleep 0.3; done
    if pgrep -f "$copies" >/dev/null; then
        # A report being handed over has a claim naming the process handing it over.
        for pid in $(pgrep -f "$copies"); do
            if grep -rlsqE --include=claim.json "\"handingOverIn\" *: *$pid([^0-9]|\$)" "$inbox"; then
                echo "The running copy of $name is handing a report over to its chat and quits once the chat has it; run this again then." >&2
                exit 1
            fi
        done
        pkill -KILL -f "$copies" 2>/dev/null || true
        for _ in {1..20}; do pgrep -f "$copies" >/dev/null || break; sleep 0.1; done
    fi
    if pgrep -f "$copies" >/dev/null; then
        echo "The running copy of $name did not exit; quit it and run this again." >&2
        exit 1
    fi
}
stop_running_copies "Redline" "$HOME/Library/Application Support/Redline/inbox"
# The app from before the rename is stopped the same way. Its inbox is still under its own name
# while it runs: the new app moves that folder when it starts.
stop_running_copies "Agentic Debugging" "$HOME/Library/Application Support/iOSAgenticDebuggingKit/inbox"
legacy="$destination/Agentic Debugging.app"
rm -rf "$legacy"
rm -rf "$app"
mv "$staging" "$app"
# Registered with Launch Services, so chats find the app by its identifier in any folder.
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$app" || true
if $running; then open -g "$app"; fi
echo "Built $app"
