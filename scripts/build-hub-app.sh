#!/bin/zsh
# Builds "Redline.app", the hub as a menu bar app, from this package and signs it for
# local use. Installs it in ~/Applications unless a destination folder is given, and registers it
# with Launch Services. A running copy, from any folder, is stopped to replace it and opened again.
# With --no-start, only a copy in the destination is stopped, and the app is neither opened again
# nor registered. The app from before the rename, "Agentic Debugging.app", is replaced too, unless
# --keep-earlier-app is given.
#
#   scripts/build-hub-app.sh [destination folder] [--no-start] [--keep-earlier-app]
set -euo pipefail
cd "$(dirname "$0")/.."
destination="$HOME/Applications"
reopen=true
replace_earlier=true
for argument in "$@"; do
    case "$argument" in
        --no-start) reopen=false ;;
        --keep-earlier-app) replace_earlier=false ;;
        *) destination="$argument" ;;
    esac
done
# Absolute, so Launch Services registers and opens the app by its full path, and with --no-start
# the running copy's process, which it starts by that path, matches the checks below.
mkdir -p "$destination"
destination="$(cd "$destination" && pwd -P)"
swift build -c release --product redline
binary="$(swift build -c release --show-bin-path)/redline"
# The same as `version` in Sources/RedlineTool/main.swift, which the MCP server reports.
version="0.1.3"
app="$destination/Redline.app"
# One temporary folder for the bundle being built and its icon, removed however the script ends.
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
    <key>CFBundleShortVersionString</key><string>$version</string>
    <key>LSMinimumSystemVersion</key><string>15.0</string>
    <key>LSUIElement</key><true/>
    <key>NSLocalNetworkUsageDescription</key><string>Redline takes the reports your apps send from iPhones on this network, and notices when a paired iPhone wakes.</string>
    <key>NSBonjourServices</key><array><string>_remotepairing._tcp</string></array>
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
# A running copy is stopped first and opened again after, unless --no-start was given: macOS may
# not match a running app to a bundle replaced under it, and ask for permissions again. A stop
# signal, not an AppleScript quit, which would need its own permission. The bundle is replaced
# only once the old copy has exited, so the open below starts the new one. Asked to stop, the app
# first lets the reports it is handing over reach their chats, which can take minutes. One that
# hasn't exited after about 15 seconds is killed only when it isn't handing a report over: killed
# mid hand-over, the next hub would hand the report over again while the chat the old one started
# still has it.
# Any installed copy is matched, not only the one in this destination: the copy running from an
# earlier destination holds the hub's lock, so the new one could not start while it runs. With
# --no-start, which starts nothing, only the copy in this destination is, so a test install leaves
# the copy the Mac runs alone. The match is the bundle's own executable path, so another app that
# happens to share the bundle name is left alone.
running=false
stop_running_copies() {
    local name="$1" executable="$2" inbox="$3" folder="" processes
    if ! $reopen; then folder="$destination"; fi
    # pgrep and pkill take a regular expression, so the path's special characters are escaped.
    processes="$(printf '%s' "$folder/$name.app/Contents/MacOS/$executable" | sed 's/[][\.*^$+?(){}|]/\\&/g')( |\$)"
    pkill -TERM -f "$processes" 2>/dev/null || return 0
    running=true
    for _ in {1..50}; do pgrep -f "$processes" >/dev/null || break; sleep 0.3; done
    if pgrep -f "$processes" >/dev/null; then
        # A report being handed over has a claim naming the process handing it over.
        for pid in $(pgrep -f "$processes"); do
            if grep -rlsqE --include=claim.json "\"handingOverIn\" *: *$pid([^0-9]|\$)" "$inbox"; then
                echo "The running copy of $name is handing a report over to its chat and quits once the chat has it; run this again then." >&2
                exit 1
            fi
        done
        pkill -KILL -f "$processes" 2>/dev/null || true
        for _ in {1..20}; do pgrep -f "$processes" >/dev/null || break; sleep 0.1; done
    fi
    if pgrep -f "$processes" >/dev/null; then
        echo "The running copy of $name did not exit; quit it and run this again." >&2
        exit 1
    fi
}
stop_running_copies "Redline" "redline" "$HOME/Library/Application Support/Redline/inbox"
# The app from before the rename is replaced the same way. Its inbox is still under its own name
# while it runs: the new app moves that folder when it starts. With --keep-earlier-app it is left
# for the caller: the installer stops it, moves its folder and removes it in its own steps.
if $replace_earlier; then
    stop_running_copies "Agentic Debugging" "agentic-debugging" "$HOME/Library/Application Support/iOSAgenticDebuggingKit/inbox"
    rm -rf "$destination/Agentic Debugging.app"
fi
rm -rf "$app"
mv "$staging" "$app"
# Registered with Launch Services, so chats find the app by its identifier in any folder. Not with
# --no-start, which leaves the rest of the system as it is, such as for a test install.
if $reopen; then
    /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$app" || true
fi
if $running; then
    if $reopen; then open -g "$app"; else echo "Stopped the running Redline to replace it; not opened again (--no-start)"; fi
fi
echo "Built $app"
