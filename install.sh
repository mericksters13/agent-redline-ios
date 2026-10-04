#!/bin/bash
# Installs, updates or removes Redline on this Mac.
#
# Run it from a checkout or from the npm package and it builds the source next to it. Piped from
# curl, it downloads the source first: REDLINE_REPO and REDLINE_REF choose another repository or
# branch (for forks and testing).
#
#   bash install.sh               install, or update
#   bash install.sh uninstall     remove Redline and keep saved reports
#   bash install.sh --no-start    install without starting Redline or adding the login item
#   bash install.sh --help
#
# Written for the bash 3.2 that ships with macOS. Everything runs from main, called on the last
# line, so a download cut short runs nothing.

set -u

DEFAULT_REPO="https://github.com/mericksters13/agent-redline-ios"
APP="$HOME/Applications/Redline.app"
BIN_DIR="$HOME/.local/bin"
COMMAND="$BIN_DIR/redline"
DATA="$HOME/Library/Application Support/Redline"
REPORT="$DATA/install-report.txt"
LOG="$DATA/install.log"
CACHE="$HOME/Library/Caches/Redline"
LABEL="com.agentredline.hub"
LAUNCH_AGENT="$HOME/Library/LaunchAgents/$LABEL.plist"
ZPROFILE="$HOME/.zprofile"
# Added to ~/.zprofile when ~/.local/bin isn't on PATH. Removed on uninstall by this exact text.
# shellcheck disable=SC2016 # $HOME and $PATH are for the login shell to expand.
PATH_LINE='export PATH="$HOME/.local/bin:$PATH" # Added by the Redline installer'
MIN_FREE_GB=3
CLAUDE_DESKTOP_VERSION="2.1.285"
CLAUDE_INSTALL="curl -fsSL https://claude.ai/install.sh | bash"

ACTION="install"
NO_START=false
CHECKLIST=""
NEEDS_YOU=0
SOURCE=""
SOURCE_NOTE=""
CLAUDE=""

usage() {
    cat <<'USAGE'
Installs Redline on this Mac: the redline command, the Redline menu bar app, the Codex hook and
Claude Code's MCP server. Running it again updates Redline.

Usage:
  install.sh                install or update
  install.sh uninstall      remove Redline; saved reports stay
  install.sh --no-start     install, but don't start Redline or add the login item
                            (for tests and CI); with uninstall, leave launchd alone
  install.sh --help         show this

Through npm: npx agent-redline-ios [uninstall]
Through curl: curl -fsSL https://raw.githubusercontent.com/mericksters13/agent-redline-ios/main/install.sh | bash

Piped from curl, it downloads the source from REDLINE_REPO (default
https://github.com/mericksters13/agent-redline-ios) at REDLINE_REF (default main).
USAGE
}

step() {
    printf '\n==> %s\n' "$1"
}

# Adds a line to the checklist: a status (Done, Needs you, Skipped, Stopped) and one or more lines
# of text, the later ones indented under the first. Paths in the home folder are shown with ~.
item() {
    local status="$1" first=true line tilde="~"
    shift
    [ "$status" = "Needs you" ] && NEEDS_YOU=$((NEEDS_YOU + 1))
    for line in "$@"; do
        line="${line//"$HOME"\//$tilde/}"
        if $first; then
            CHECKLIST="$CHECKLIST$(printf '  %-10s %s' "$status" "$line")"$'\n'
            first=false
        else
            CHECKLIST="$CHECKLIST             $line"$'\n'
        fi
    done
}

# Prints the checklist and saves it, with the date, to the report file.
finish() {
    local title="$1" summary="$2" tmp
    printf '\n%s\n\n%s\n%s\n' "$title" "$CHECKLIST" "$summary"
    mkdir -p "$DATA" 2>/dev/null || return 0
    tmp="$REPORT.tmp.$$"
    if printf '%s, %s\n\n%s\n%s\n' "$title" "$(date '+%Y-%m-%d %H:%M')" "$CHECKLIST" "$summary" >"$tmp" 2>/dev/null; then
        mv -f "$tmp" "$REPORT"
        printf 'This checklist is saved in %s\n' "$REPORT"
    else
        rm -f "$tmp"
    fi
}

# Stops when installing can't go on, with what went wrong and the one fix, then exits non-zero.
stop() {
    local problem="$1" fix="$2"
    item "Stopped" "$problem" "$fix" "Then run the same command again."
    finish "$([ "$ACTION" = "uninstall" ] && echo "Redline was not removed." || echo "Redline is not installed.")" "Stopped: $problem
To fix it: $fix
Then run the same command again."
    exit 1
}

# The log of the build and of each command the installer runs, started fresh each time.
start_log() {
    mkdir -p "$DATA" || stop "Couldn't create $DATA." "Check that you can write to $HOME/Library/Application Support."
    printf 'Redline installer, %s, %s\n' "$ACTION" "$(date)" >"$LOG"
}

# True when there is a terminal to ask in. Checks /dev/tty, not standard input: piped from curl,
# standard input is the script itself.
can_ask() {
    (: </dev/tty) 2>/dev/null
}

# True when version $1 is older than version $2, comparing up to three numbers.
older_than() {
    awk -v a="$1" -v b="$2" 'BEGIN {
        split(a, x, "."); split(b, y, ".")
        for (i = 1; i <= 3; i++) { if (x[i] + 0 < y[i] + 0) exit 0; if (x[i] + 0 > y[i] + 0) exit 1 }
        exit 1
    }'
}

# The last error lines of the log, or its last lines when it names no error.
show_log_errors() {
    local errors
    errors="$(grep -E '(error|fatal):' "$LOG" | tail -n 8)"
    [ -n "$errors" ] || errors="$(tail -n 15 "$LOG")"
    printf '%s\n' "$errors" | sed 's/^/    /'
}

find_claude() {
    local candidate
    CLAUDE="$(command -v claude 2>/dev/null || true)"
    if [ -z "$CLAUDE" ]; then
        for candidate in "$HOME/.local/bin/claude" /opt/homebrew/bin/claude /usr/local/bin/claude; do
            if [ -x "$candidate" ]; then
                CLAUDE="$candidate"
                break
            fi
        done
    fi
}

# The command line of Claude Code's user-scoped MCP server named $1, or nothing. Read from the
# settings file, because "claude mcp get" starts the server to check it.
mcp_entry() {
    local config="${CLAUDE_CONFIG_DIR:-$HOME}/.claude.json"
    [ -f "$config" ] || return 0
    /usr/bin/osascript -l JavaScript - "$config" "$1" 2>/dev/null <<'JS'
function run(argv) {
    ObjC.import("Foundation");
    var text = $.NSString.stringWithContentsOfFileEncodingError(argv[0], $.NSUTF8StringEncoding, null);
    if (text.isNil()) return "";
    try {
        var server = (JSON.parse(text.js).mcpServers || {})[argv[1]];
        return server ? [server.command].concat(server.args || []).join(" ") : "";
    } catch (error) {
        return "";
    }
}
JS
}

preflight() {
    local macos developer xcode swift_version free_kb free_gb
    step "Checking this Mac"
    [ "$(uname -s)" = "Darwin" ] || stop "Redline runs on macOS only." "Run the installer on a Mac."
    [ "$(id -u)" -ne 0 ] || stop "The installer is running as root." "Run it as yourself, without sudo."

    macos="$(sw_vers -productVersion)"
    [ "${macos%%.*}" -ge 15 ] 2>/dev/null ||
        stop "Redline needs macOS 15 or later; this Mac has macOS $macos." "Update macOS in System Settings > General > Software Update."

    developer="$(xcode-select -p 2>/dev/null || true)"
    case "$developer" in
        *.app/Contents/Developer) ;;
        *)
            xcode="$(find /Applications -maxdepth 1 -name 'Xcode*.app' 2>/dev/null | sort | head -n 1)"
            if [ -n "$xcode" ]; then
                stop "Xcode is installed but not selected (the selected developer folder is ${developer:-none})." \
                    "Select it: sudo xcode-select -s \"$xcode/Contents/Developer\""
            fi
            stop "Redline needs Xcode: it builds Redline and reaches your iPhone." \
                "Install Xcode from the App Store (https://apps.apple.com/app/xcode/id497799835) and open it once."
            ;;
    esac
    xcodebuild -license check >/dev/null 2>&1 ||
        stop "The Xcode license hasn't been accepted." "Accept it: sudo xcodebuild -license accept"
    xcodebuild -checkFirstLaunchStatus >/dev/null 2>&1 ||
        stop "Xcode hasn't finished installing its components." "Finish it: sudo xcodebuild -runFirstLaunch"
    xcode="$(xcodebuild -version 2>/dev/null | head -n 1)"
    xcrun --find devicectl >/dev/null 2>&1 ||
        stop "The selected Xcode ($developer) has no devicectl, which Redline uses to reach iPhones." \
            "Install Xcode 16 or later and select it: sudo xcode-select -s /Applications/Xcode.app/Contents/Developer"
    xcrun --find swift >/dev/null 2>&1 ||
        stop "The selected Xcode ($developer) has no swift." "Reinstall Xcode from the App Store, then open it once."
    swift_version="$(swift --version 2>/dev/null | sed -n 's/.*Swift version \([0-9][0-9.]*\).*/\1/p' | head -n 1)"
    [ "${swift_version%%.*}" -ge 6 ] 2>/dev/null ||
        stop "Redline needs Swift 6 or later; swift is ${swift_version:-missing}." \
            "Install Xcode 16 or later and select it: sudo xcode-select -s /Applications/Xcode.app/Contents/Developer"
    git --version >/dev/null 2>&1 ||
        stop "git isn't working." "Select Xcode, which includes git: sudo xcode-select -s /Applications/Xcode.app/Contents/Developer"

    free_kb="$(df -Pk "$HOME" | awk 'NR == 2 { print $4 }')"
    free_gb=$((free_kb / 1024 / 1024))
    [ "$free_gb" -ge "$MIN_FREE_GB" ] ||
        stop "Building Redline needs $MIN_FREE_GB GB of free disk space; $free_gb GB is free." \
            "Free up space, for example in System Settings > General > Storage."

    item "Done" "This Mac: macOS $macos, $xcode, Swift $swift_version, $free_gb GB free"
}

# Uses the checkout or npm package this script is in. Piped from curl, downloads the source into a
# cached clone, cloning into a new folder first so a failed download leaves the old one as it was.
find_source() {
    local script="${BASH_SOURCE[0]:-}" folder repo ref clone
    if [ -n "$script" ] && [ -f "$script" ]; then
        folder="$(cd "$(dirname "$script")" && pwd -P)"
        if [ -f "$folder/Package.swift" ] && [ -d "$folder/Sources/RedlineTool" ]; then
            SOURCE="$folder"
            if [ -d "$folder/.git" ] || [ -f "$folder/.git" ]; then SOURCE_NOTE="this checkout"; else SOURCE_NOTE="the package"; fi
            item "Done" "Source: $SOURCE_NOTE, $SOURCE"
            return
        fi
    fi

    repo="${REDLINE_REPO:-$DEFAULT_REPO}"
    ref="${REDLINE_REF:-main}"
    step "Downloading Redline from $repo ($ref)"
    SOURCE="$CACHE/source"
    SOURCE_NOTE="$repo ($ref)"
    if [ -d "$SOURCE/.git" ] && [ "$(git -C "$SOURCE" remote get-url origin 2>/dev/null)" = "$repo" ] &&
        git -C "$SOURCE" fetch --quiet --depth 1 origin "$ref" >>"$LOG" 2>&1 &&
        git -C "$SOURCE" reset --quiet --hard FETCH_HEAD >>"$LOG" 2>&1; then
        item "Done" "Source: updated $SOURCE_NOTE in $SOURCE"
        return
    fi
    mkdir -p "$CACHE" || stop "Couldn't create $CACHE." "Check that you can write to $HOME/Library/Caches."
    clone="$(mktemp -d "$CACHE/download.XXXXXX")" || stop "Couldn't create a folder in $CACHE." "Check that you can write to $HOME/Library/Caches."
    if ! git clone --quiet --depth 1 --branch "$ref" "$repo" "$clone/source" >>"$LOG" 2>&1; then
        rm -rf "$clone"
        show_log_errors
        stop "Couldn't download Redline from $repo ($ref)." "Check your internet connection."
    fi
    rm -rf "$SOURCE"
    mv "$clone/source" "$SOURCE"
    rm -rf "$clone"
    item "Done" "Source: downloaded $SOURCE_NOTE to $SOURCE"
}

build_command() {
    step "Building the redline command (a few minutes the first time; log: $LOG)"
    if ! (cd "$SOURCE" && swift build -c release --product redline) >>"$LOG" 2>&1; then
        show_log_errors
        stop "The build failed. The full log is $LOG." "Fix the error above; an Xcode update or opening Xcode once often does."
    fi
    BUILT="$(cd "$SOURCE" && swift build -c release --show-bin-path 2>>"$LOG")/redline"
    [ -x "$BUILT" ] || stop "The build finished without the redline command (looked for $BUILT)." "Read $LOG for what went wrong."
    item "Done" "Built the redline command"
}

# Copies the command from the build output; never from the app bundle, where macOS stops a copy.
install_command() {
    local tmp
    step "Installing the redline command"
    mkdir -p "$BIN_DIR" || stop "Couldn't create $BIN_DIR." "Check that you can write to $HOME."
    tmp="$BIN_DIR/.redline.new.$$"
    if ! { cp "$BUILT" "$tmp" && chmod 755 "$tmp" && mv -f "$tmp" "$COMMAND"; }; then
        rm -f "$tmp"
        stop "Couldn't copy the redline command to $COMMAND." "Check that you can write to $BIN_DIR."
    fi
    item "Done" "Command: $COMMAND"

    case ":$PATH:" in
        *":$BIN_DIR:"*)
            item "Done" "PATH: $BIN_DIR is on your PATH"
            ;;
        *)
            if grep -qxF "$PATH_LINE" "$ZPROFILE" 2>/dev/null; then
                item "Done" "PATH: $ZPROFILE adds $BIN_DIR (from an earlier install); new terminals find redline"
            else
                if [ -s "$ZPROFILE" ] && [ -n "$(tail -c 1 "$ZPROFILE")" ]; then printf '\n' >>"$ZPROFILE"; fi
                printf '%s\n' "$PATH_LINE" >>"$ZPROFILE"
                item "Needs you" "PATH: added $BIN_DIR to your PATH in $ZPROFILE." "Open a new terminal window to use the redline command."
            fi
            ;;
    esac
}

install_app() {
    step "Building and installing Redline.app"
    if ! /bin/zsh "$SOURCE/scripts/build-hub-app.sh" "$HOME/Applications" >>"$LOG" 2>&1; then
        show_log_errors
        stop "Building Redline.app failed. The full log is $LOG." "Fix the error above; an Xcode update or opening Xcode once often does."
    fi
    item "Done" "App: $APP"
}

# Runs redline setup: the claude command check and the Codex hook. With a terminal it can run
# claude update and claude auth login; without one it only says what's left.
run_setup() {
    local status
    step "Setting up Claude Code and Codex"
    if can_ask; then
        "$COMMAND" setup </dev/tty
        status=$?
    else
        "$COMMAND" setup --no-input 2>&1 | tee -a "$LOG"
        status=${PIPESTATUS[0]}
    fi
    if [ "$status" -eq 0 ]; then
        item "Done" "Setup: ran redline setup"
    else
        item "Needs you" "Setup: redline setup couldn't write a settings file (named above)." \
            "Fix or move that file, then run: $COMMAND setup"
    fi
}

# What the claude command still needs, from the user, to start new chats.
check_claude() {
    local version
    find_claude
    if [ -z "$CLAUDE" ]; then
        if [ -d "$HOME/.claude" ] || [ -d /Applications/Claude.app ]; then
            item "Needs you" "Claude Code: the claude command isn't installed. It starts new chats for reports and runs Redline's MCP server." \
                "Run: $CLAUDE_INSTALL" "Then run the installer again to add the MCP server."
        else
            item "Skipped" "Claude Code: not used on this Mac. To use it later, install it ($CLAUDE_INSTALL) and run the installer again."
        fi
        return
    fi
    version="$("$CLAUDE" --version 2>/dev/null | awk '{ print $1 }')"
    if [ -d /Applications/Claude.app ] && older_than "${version:-0}" "$CLAUDE_DESKTOP_VERSION"; then
        item "Needs you" "Claude Code: the claude command (${version:-unknown version}) is too old to open new chats in the Claude app." "Run: claude update"
    fi
    if "$CLAUDE" auth status >/dev/null 2>&1; then
        item "Done" "Claude Code: the claude command is signed in"
    else
        item "Needs you" "Claude Code: the claude command isn't signed in. It starts new chats for reports, with its own sign-in, separate from the Claude app's." \
            "Run: claude auth login"
    fi
}

# Registers Redline's MCP server with Claude Code once, replacing the entry from before the rename.
register_mcp() {
    local have note=""
    [ -n "$CLAUDE" ] || return 0
    step "Adding Redline's MCP server to Claude Code"
    if [ -n "$(mcp_entry agentic-debugging)" ]; then
        "$CLAUDE" mcp remove --scope user agentic-debugging >>"$LOG" 2>&1 && note="; removed the old agentic-debugging entry"
    fi
    have="$(mcp_entry redline)"
    if [ "$have" = "$COMMAND mcp" ]; then
        item "Done" "MCP server: Claude Code already runs redline mcp$note"
        return
    fi
    [ -z "$have" ] || "$CLAUDE" mcp remove --scope user redline >>"$LOG" 2>&1
    if "$CLAUDE" mcp add --scope user redline -- "$COMMAND" mcp >>"$LOG" 2>&1; then
        item "Done" "MCP server: added to Claude Code (user scope) as redline$note"
    else
        item "Needs you" "MCP server: couldn't add it to Claude Code (see $LOG)." "Run: claude mcp add --scope user redline -- $COMMAND mcp"
    fi
}

# Prints the login item's property list, which opens Redline in the background at login.
launch_agent_plist() {
    cat <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>$LABEL</string>
    <key>ProgramArguments</key>
    <array>
        <string>/usr/bin/open</string>
        <string>-g</string>
        <string>$APP</string>
    </array>
    <key>RunAtLoad</key><true/>
</dict>
</plist>
PLIST
}

start_redline() {
    local domain tmp loaded=false try
    if $NO_START; then
        item "Skipped" "Login item and start (--no-start). To start Redline, run: open $APP"
        return
    fi
    step "Opening Redline at login and now"
    domain="gui/$(id -u)"
    mkdir -p "$(dirname "$LAUNCH_AGENT")"
    tmp="$LAUNCH_AGENT.new.$$"
    launch_agent_plist >"$tmp"
    if cmp -s "$tmp" "$LAUNCH_AGENT" && launchctl print "$domain/$LABEL" >/dev/null 2>&1; then
        rm -f "$tmp"
        item "Done" "Login item: Redline opens at login ($LAUNCH_AGENT)"
    else
        launchctl bootout "$domain/$LABEL" >/dev/null 2>&1 || true
        mv -f "$tmp" "$LAUNCH_AGENT"
        # A service just booted out can take a moment to go.
        for try in 1 2 3 4 5; do
            if launchctl bootstrap "$domain" "$LAUNCH_AGENT" >>"$LOG" 2>&1; then
                loaded=true
                break
            fi
            sleep "$try"
        done
        if $loaded; then
            item "Done" "Login item: Redline opens at login ($LAUNCH_AGENT)"
        else
            item "Needs you" "Login item: couldn't load $LAUNCH_AGENT (see $LOG)." "Run: launchctl bootstrap $domain $LAUNCH_AGENT"
        fi
    fi

    open -g "$APP" >>"$LOG" 2>&1
    for try in 1 2 3 4 5 6 7 8 9 10; do
        if pgrep -f "$APP/Contents/MacOS/" >/dev/null 2>&1; then
            item "Done" "Redline is running: its icon is in the menu bar"
            return
        fi
        sleep 1
    done
    item "Needs you" "Redline didn't start." "Run: open $APP" "If it still doesn't start, its log is $DATA/hub/hub.log"
}

check_codex() {
    if grep -q 'Report delivery' "$HOME/.codex/hooks.json" 2>/dev/null; then
        item "Needs you" "Codex: trust the Report delivery hook, once. Codex runs a new hook only after you trust it." \
            "In Codex, open /hooks and trust \"Report delivery\"."
    elif [ -x /opt/homebrew/bin/codex ] || [ -x /usr/local/bin/codex ] || [ -d /Applications/Codex.app ] || [ -d /Applications/ChatGPT.app/Contents/Resources/codex-cli ]; then
        item "Skipped" "Codex: installed but not used yet (no $HOME/.codex), so no hook was added. After you first use it, run: $COMMAND setup"
    else
        item "Skipped" "Codex: not used on this Mac"
    fi
}

install() {
    start_log
    preflight
    find_source
    build_command
    install_command
    install_app
    run_setup
    check_claude
    register_mcp
    start_redline
    check_codex
    local summary
    if [ "$NEEDS_YOU" -eq 0 ]; then
        summary="Redline is installed. Nothing needs you."
    else
        summary="Redline is installed. $NEEDS_YOU $([ "$NEEDS_YOU" -eq 1 ] && echo "item needs" || echo "items need") you: see Needs you above."
    fi
    summary="$summary
Next: add Redline to your iOS app. Add the package https://github.com/mericksters13/agent-redline-ios
(product Redline) and .redline() on the root view; INSTALL.md and the README show how."
    finish "Redline install checklist" "$summary"
}

uninstall() {
    local domain have status try
    start_log
    step "Removing Redline"
    [ "$(id -u)" -ne 0 ] || stop "The installer is running as root." "Run it as yourself, without sudo."

    if [ -x "$COMMAND" ]; then
        "$COMMAND" remove >>"$LOG" 2>&1
        status=$?
        if [ "$status" -eq 0 ]; then
            item "Done" "Hooks: removed Redline's hooks; other hooks stay"
        else
            item "Needs you" "Hooks: couldn't update a settings file (see $LOG)." "Remove the \"Report delivery\" hook from $HOME/.codex/hooks.json by hand."
        fi
    else
        item "Skipped" "Hooks: the redline command isn't installed, so there was nothing to remove them with"
    fi

    find_claude
    if [ -n "$CLAUDE" ]; then
        for have in redline agentic-debugging; do
            if [ -n "$(mcp_entry "$have")" ]; then
                if "$CLAUDE" mcp remove --scope user "$have" >>"$LOG" 2>&1; then
                    item "Done" "MCP server: removed $have from Claude Code"
                else
                    item "Needs you" "MCP server: couldn't remove $have (see $LOG)." "Run: claude mcp remove --scope user $have"
                fi
            fi
        done
    fi

    if [ -f "$LAUNCH_AGENT" ]; then
        domain="gui/$(id -u)"
        # Only the service this home folder's app runs, never one with the same label for another.
        if ! $NO_START && launchctl print "$domain/$LABEL" 2>/dev/null | grep -qF "$APP"; then
            launchctl bootout "$domain/$LABEL" >>"$LOG" 2>&1 || true
        fi
        rm -f "$LAUNCH_AGENT"
        item "Done" "Login item: removed"
    fi

    if pkill -TERM -f "$APP/Contents/MacOS/" 2>/dev/null; then
        for try in 1 2 3 4 5 6 7 8 9 10; do pgrep -f "$APP/Contents/MacOS/" >/dev/null || break; sleep 0.3; done
        item "Done" "Stopped Redline"
    fi

    if [ -e "$APP" ] || [ -e "$COMMAND" ]; then
        rm -rf "$APP"
        rm -f "$COMMAND"
        item "Done" "Removed $APP and $COMMAND"
    else
        item "Skipped" "The app and the command were already removed"
    fi

    if grep -qxF "$PATH_LINE" "$ZPROFILE" 2>/dev/null; then
        grep -vxF "$PATH_LINE" "$ZPROFILE" >"$ZPROFILE.redline.$$" || true
        cat "$ZPROFILE.redline.$$" >"$ZPROFILE"
        rm -f "$ZPROFILE.redline.$$"
        item "Done" "PATH: removed the installer's line from $ZPROFILE"
    fi

    rm -rf "$CACHE"
    item "Done" "Kept your reports in $DATA. Delete that folder to remove them."
    finish "Redline uninstall checklist" "Redline is removed. In your app, remove the .redline() line and the Redline package."
}

main() {
    local argument
    for argument in "$@"; do
        case "$argument" in
            uninstall) ACTION="uninstall" ;;
            --no-start) NO_START=true ;;
            -h | --help)
                usage
                exit 0
                ;;
            *)
                printf 'Unknown option: %s\n\n' "$argument" >&2
                usage >&2
                exit 64
                ;;
        esac
    done
    if [ "$ACTION" = "uninstall" ]; then uninstall; else install; fi
    exit 0
}

# Standard input is closed for everything the installer runs: piped from curl, it is the script.
main "$@" </dev/null
