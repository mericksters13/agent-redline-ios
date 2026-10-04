#!/bin/bash
# Installs, updates or removes Redline on this Mac.
#
# Run it from a checkout or from the npm package and it builds the source next to it. Piped from
# curl, it downloads the source first: REDLINE_REPO and REDLINE_REF choose another repository and
# branch, tag or commit (for forks, testing and pinned installs).
#
#   bash install.sh               install, or update
#   bash install.sh uninstall     remove Redline and keep saved reports
#   bash install.sh --no-input    never wait for input; list what needs you instead
#   bash install.sh --no-start    install without starting Redline or adding the login item
#   bash install.sh --help
#
# Written for the bash 3.2 that ships with macOS. Everything runs from main, called on the last
# line, so a download cut short runs nothing.

set -u
# The system's tools first: Xcode's swift and git through /usr/bin, then whatever else is on PATH.
PATH="/usr/bin:/bin:/usr/sbin:/sbin${PATH:+:$PATH}"
export PATH

DEFAULT_REPO="https://github.com/mericksters13/agent-redline-ios"
LABEL="com.agentredline.hub"
# Added to ~/.zprofile when ~/.local/bin isn't on PATH. Removed on uninstall by this exact text.
# shellcheck disable=SC2016 # $HOME and $PATH are for the login shell to expand.
PATH_LINE='export PATH="$HOME/.local/bin:$PATH" # Added by the Redline installer'
# shellcheck disable=SC2016
PATH_EXPORT='export PATH="$HOME/.local/bin:$PATH"'
MIN_FREE_GB=3
CLAUDE_DESKTOP_VERSION="2.1.285"
CLAUDE_INSTALL="curl -fsSL https://claude.ai/install.sh | bash"

ACTION="install"
NO_START=false
NO_INPUT=false
CHECKLIST=""
NEEDS_YOU=0
SOURCE=""
CLAUDE=""
BUILT=""
SETUP_OK=false
# Temporary files and folders, removed when the installer exits, however it exits.
TMP_CLONE=""
TMP_BIN=""
TMP_PLIST=""
TMP_REPORT=""
TMP_ZPROFILE=""

# The paths in the home folder, set once HOME is checked.
set_paths() {
    APP="$HOME/Applications/Redline.app"
    OLD_APP="$HOME/Applications/Agentic Debugging.app"
    BIN_DIR="$HOME/.local/bin"
    COMMAND="$BIN_DIR/redline"
    OLD_COMMAND="$BIN_DIR/agentic-debugging"
    DATA="$HOME/Library/Application Support/Redline"
    OLD_DATA="$HOME/Library/Application Support/iOSAgenticDebuggingKit"
    REPORT="$DATA/install-report.txt"
    LOG="$DATA/install.log"
    CACHE="$HOME/Library/Caches/Redline"
    LAUNCH_AGENT="$HOME/Library/LaunchAgents/$LABEL.plist"
    ZPROFILE="$HOME/.zprofile"
}

usage() {
    cat <<'USAGE'
Installs Redline on this Mac: the redline command, the Redline menu bar app, the Codex hook and
Claude Code's MCP server. Running it again updates Redline.

Usage:
  install.sh                install or update
  install.sh uninstall      remove Redline; saved reports stay
  install.sh --no-input     never wait for input: don't run claude update or claude auth login,
                            list them instead. On by default when a coding agent or CI runs it,
                            and with REDLINE_NO_INPUT=1.
  install.sh --no-start     install, but don't start Redline or add the login item
                            (for tests and CI); with uninstall, leave launchd alone
  install.sh --help         show this

Through npm: npx agent-redline-ios [uninstall]
Through curl: curl -fsSL https://raw.githubusercontent.com/mericksters13/agent-redline-ios/main/install.sh | bash

Piped from curl, it downloads the source from REDLINE_REPO (default
https://github.com/mericksters13/agent-redline-ios) at REDLINE_REF (a branch, tag or commit;
default main).
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

# shellcheck disable=SC2329 # Run by the EXIT trap.
cleanup() {
    if [ -n "$TMP_CLONE" ]; then rm -rf "$TMP_CLONE"; fi
    if [ -n "$TMP_BIN" ]; then rm -f "$TMP_BIN"; fi
    if [ -n "$TMP_PLIST" ]; then rm -f "$TMP_PLIST"; fi
    if [ -n "$TMP_REPORT" ]; then rm -f "$TMP_REPORT"; fi
    if [ -n "$TMP_ZPROFILE" ]; then rm -f "$TMP_ZPROFILE"; fi
}

# Prints the checklist and saves it, with the date, to the report file.
finish() {
    local title="$1" summary="$2"
    printf '\n%s\n\n%s\n%s\n' "$title" "$CHECKLIST" "$summary"
    mkdir -p "$DATA" 2>/dev/null || return 0
    TMP_REPORT="$REPORT.tmp.$$"
    if printf '%s, %s\n\n%s\n%s\n' "$title" "$(date '+%Y-%m-%d %H:%M')" "$CHECKLIST" "$summary" >"$TMP_REPORT" 2>/dev/null &&
        mv -f "$TMP_REPORT" "$REPORT"; then
        TMP_REPORT=""
        printf 'This checklist is saved in %s\n' "$REPORT"
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

# Stops before the report folder is written to, because it can't be, or must not be yet.
stop_early() {
    printf 'Stopped: %s\nTo fix it: %s\nThen run the same command again.\n' "$1" "$2" >&2
    exit 1
}

# The log of the build and of each command the installer runs, started fresh each time.
start_log() {
    mkdir -p "$DATA" || stop_early "Couldn't create $DATA." "Check that you can write to $HOME/Library/Application Support."
    printf 'Redline installer, %s, %s\n' "$ACTION" "$(date)" >"$LOG" ||
        stop_early "Couldn't write $LOG." "Check that you own that folder: ls -ld \"$DATA\""
}

# True when there is someone to ask: not turned off, standard output is a terminal, and /dev/tty
# opens. Checks /dev/tty, not standard input: piped from curl, standard input is the script.
can_ask() {
    ! $NO_INPUT && [ -t 1 ] && (: </dev/tty) 2>/dev/null
}

# True when version $1 is older than version $2, comparing up to three numbers.
older_than() {
    awk -v a="$1" -v b="$2" 'BEGIN {
        split(a, x, "."); split(b, y, ".")
        for (i = 1; i <= 3; i++) { if (x[i] + 0 < y[i] + 0) exit 0; if (x[i] + 0 > y[i] + 0) exit 1 }
        exit 1
    }'
}

# The last error lines of a log ($LOG unless one is given), or its last lines when it names no error.
show_log_errors() {
    local log="${1:-$LOG}" errors
    errors="$(grep -E '(error|fatal):' "$log" | tail -n 8)"
    [ -n "$errors" ] || errors="$(tail -n 15 "$log")"
    printf '%s\n' "$errors" | sed 's/^/    /'
}

# The extended regular expression that matches the processes of the app at $1, for pgrep -f.
app_processes() {
    printf '%s' "$1/Contents/MacOS/" | sed 's/[][\.*^$+?(){}|]/\\&/g'
}

# Stops the app at $1 if it is running and waits for it to go. True when it was running.
stop_app() {
    local pattern try
    pattern="$(app_processes "$1")"
    pkill -TERM -f "$pattern" 2>/dev/null || return 1
    for try in 1 2 3 4 5 6 7 8 9 10; do
        pgrep -f "$pattern" >/dev/null || break
        sleep 0.3
    done
    return 0
}

# The settings file that the output ($1) of redline setup or remove says it couldn't update.
failed_settings_file() {
    printf '%s\n' "$1" | sed -n "s/.*couldn't update \([^:]*\): .*/\1/p" | head -n 1
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

# Removes Redline's hooks from the agent settings file $1 without the redline command, the way
# redline remove does: hooks that run a command named redline or agentic-debugging go, groups
# left empty go, everything else stays. Prints removed, unchanged, unreadable or unwritable.
remove_hooks_from() {
    /usr/bin/osascript -l JavaScript - "$1" 2>/dev/null <<'JS'
function run(argv) {
    ObjC.import("Foundation");
    var text = $.NSString.stringWithContentsOfFileEncodingError(argv[0], $.NSUTF8StringEncoding, null);
    if (text.isNil()) return "unchanged";
    var settings;
    try { settings = JSON.parse(text.js); } catch (error) { return "unreadable"; }
    function ours(hook) {
        if (!hook || typeof hook.command !== "string") return false;
        var match = /^'((?:[^']|'\\'')*)' hook /.exec(hook.command);
        if (!match) return false;
        var name = match[1].replace(/'\\''/g, "'").split("/").pop();
        return name === "redline" || name === "agentic-debugging";
    }
    var events = settings && settings.hooks, changed = false;
    if (!events || typeof events !== "object") return "unchanged";
    Object.keys(events).forEach(function (event) {
        if (!Array.isArray(events[event])) return;
        var kept = [];
        events[event].forEach(function (entry) {
            if (ours(entry)) { changed = true; return; }
            if (entry && Array.isArray(entry.hooks)) {
                var others = entry.hooks.filter(function (hook) { return !ours(hook); });
                if (others.length !== entry.hooks.length) changed = true;
                if (others.length === 0) return;
                entry.hooks = others;
            }
            kept.push(entry);
        });
        if (kept.length) events[event] = kept; else delete events[event];
    });
    if (!changed) return "unchanged";
    if (Object.keys(events).length === 0) delete settings.hooks;
    var out = $.NSString.alloc.initWithUTF8String(JSON.stringify(settings, null, 2) + "\n");
    return out.writeToFileAtomicallyEncodingError(argv[0], true, $.NSUTF8StringEncoding, null) ? "removed" : "unwritable";
}
JS
}

# An earlier version kept its reports, paired phones and chats in another folder. Redline moves
# them on its first run, but only while its own folder doesn't exist, so the installer moves them
# before it writes its log there. A hub of the earlier version still running is stopped first.
move_old_data() {
    local pid try
    if [ ! -d "$OLD_DATA" ] || [ -e "$DATA" ]; then return 0; fi
    stop_app "$OLD_APP" || true
    pid="$(tr -d '[:space:]' <"$OLD_DATA/hub/hub.pid" 2>/dev/null)"
    case "$pid" in
        '' | *[!0-9]*) ;;
        *)
            if kill -0 "$pid" 2>/dev/null; then
                kill -TERM "$pid" 2>/dev/null
                for try in 1 2 3 4 5 6 7 8 9 10; do
                    kill -0 "$pid" 2>/dev/null || break
                    sleep 0.3
                done
                if kill -0 "$pid" 2>/dev/null; then
                    stop_early "The hub of the earlier version (Agentic Debugging, pid $pid) is still running." "Quit it: kill $pid"
                fi
            fi
            ;;
    esac
    if ! { mkdir -p "$(dirname "$DATA")" && mv "$OLD_DATA" "$DATA"; }; then
        stop_early "Couldn't move the earlier version's reports from $OLD_DATA to $DATA." \
            "Check that you can write to $HOME/Library/Application Support."
    fi
    item "Done" "Moved the earlier version's reports and paired phones from $OLD_DATA to $DATA"
}

preflight() {
    local macos developer xcode swift_version free_kb free_gb
    step "Checking this Mac"
    [ "$(uname -s)" = "Darwin" ] || stop "Redline runs on macOS only." "Run the installer on a Mac."

    macos="$(sw_vers -productVersion)"
    [ "${macos%%.*}" -ge 15 ] 2>/dev/null ||
        stop "Redline needs macOS 15 or later; this Mac has macOS $macos." "Update macOS in System Settings > General > Software Update."

    developer="$(xcode-select -p 2>/dev/null || true)"
    case "$developer" in
        *.app/Contents/Developer) ;;
        *)
            if [ -d /Applications/Xcode.app ]; then
                xcode=/Applications/Xcode.app
            else
                xcode="$(find /Applications -maxdepth 1 -name 'Xcode*.app' 2>/dev/null | sort | head -n 1)"
            fi
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

# git that never asks for a user name, password or passphrase: it fails instead.
quiet_git() {
    GIT_TERMINAL_PROMPT=0 GIT_ASKPASS=/usr/bin/false SSH_ASKPASS=/usr/bin/false \
        GIT_SSH_COMMAND="${GIT_SSH_COMMAND:-ssh} -o BatchMode=yes" git "$@"
}

# Uses the checkout this script is in, or a copy of the npm package it is in, so the build lands
# in a folder the user owns and later versions reuse it. Piped from curl, downloads the source
# into a cached clone, fetching into a new folder first so a failed download leaves the old one.
find_source() {
    local script="${BASH_SOURCE[0]:-}" folder repo ref clone
    if [ -n "$script" ] && [ -f "$script" ]; then
        folder="$(cd "$(dirname "$script")" && pwd -P)"
        if [ -f "$folder/Package.swift" ] && [ -d "$folder/Sources/RedlineTool" ]; then
            if [ -d "$folder/.git" ] || [ -f "$folder/.git" ]; then
                SOURCE="$folder"
                item "Done" "Source: this checkout, $SOURCE"
                return
            fi
            SOURCE="$CACHE/source"
            if ! { mkdir -p "$SOURCE" && rsync -a --delete --exclude .build --exclude node_modules "$folder/" "$SOURCE/"; } >>"$LOG" 2>&1; then
                stop "Couldn't copy the package from $folder to $SOURCE." "Check that you can write to $HOME/Library/Caches."
            fi
            item "Done" "Source: the package, copied to $SOURCE"
            return
        fi
    fi

    repo="${REDLINE_REPO:-$DEFAULT_REPO}"
    ref="${REDLINE_REF:-main}"
    case "$repo" in -*) stop "REDLINE_REPO ($repo) isn't a repository." "Set it to a git URL or folder, or unset it." ;; esac
    case "$ref" in -*) stop "REDLINE_REF ($ref) isn't a branch, tag or commit." "Set it to one, or unset it." ;; esac
    step "Downloading Redline from $repo ($ref)"
    SOURCE="$CACHE/source"
    if [ -d "$SOURCE/.git" ] && [ "$(git -C "$SOURCE" remote get-url origin 2>/dev/null)" = "$repo" ] &&
        quiet_git -C "$SOURCE" fetch --quiet --depth 1 origin -- "$ref" >>"$LOG" 2>&1 &&
        git -C "$SOURCE" -c advice.detachedHead=false checkout --quiet --force FETCH_HEAD >>"$LOG" 2>&1; then
        item "Done" "Source: updated $repo ($ref) in $SOURCE"
        return
    fi
    mkdir -p "$CACHE" || stop "Couldn't create $CACHE." "Check that you can write to $HOME/Library/Caches."
    clone="$(mktemp -d "$CACHE/download.XXXXXX")" || stop "Couldn't create a folder in $CACHE." "Check that you can write to $HOME/Library/Caches."
    TMP_CLONE="$clone"
    if ! { git init --quiet "$clone/source" &&
        git -C "$clone/source" remote add origin "$repo" &&
        quiet_git -C "$clone/source" fetch --quiet --depth 1 origin -- "$ref" &&
        git -C "$clone/source" -c advice.detachedHead=false checkout --quiet FETCH_HEAD; } >"$clone/git.log" 2>&1; then
        cat "$clone/git.log" >>"$LOG"
        show_log_errors "$clone/git.log"
        if grep -qiE "not found|could not read|authentication failed|terminal prompts disabled|couldn't find remote ref|does not appear to be a git repository|permission denied" "$clone/git.log"; then
            stop "Couldn't download Redline from $repo ($ref): the repository, branch or commit doesn't exist, or it needs a sign-in." \
                "Check REDLINE_REPO and REDLINE_REF, or use the npx command."
        fi
        stop "Couldn't download Redline from $repo ($ref)." "Check your internet connection."
    fi
    cat "$clone/git.log" >>"$LOG"
    # Keep the earlier build, so this one only rebuilds what changed.
    if [ -d "$SOURCE/.build" ]; then mv "$SOURCE/.build" "$clone/source/.build"; fi
    rm -rf "$SOURCE"
    mv "$clone/source" "$SOURCE" || stop "Couldn't move the download to $SOURCE." "Check that you can write to $CACHE."
    rm -rf "$clone"
    TMP_CLONE=""
    item "Done" "Source: downloaded $repo ($ref) to $SOURCE"
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

# Adds ~/.local/bin to PATH for new terminals, when it isn't on PATH already.
add_to_path() {
    local shell="${SHELL:-/bin/zsh}"
    shell="${shell##*/}"
    case ":$PATH:" in
        *":$BIN_DIR:"*)
            item "Done" "PATH: $BIN_DIR is on your PATH"
            return
            ;;
    esac
    if grep -qxF "$PATH_LINE" "$ZPROFILE" 2>/dev/null; then
        item "Done" "PATH: $ZPROFILE adds $BIN_DIR (from an earlier install); new terminals find redline"
        return
    fi
    case "$shell" in
        zsh) ;;
        bash)
            item "Needs you" "PATH: $BIN_DIR isn't on your PATH, and bash doesn't read $ZPROFILE." \
                "Add this line to ~/.bash_profile, then open a new terminal window: $PATH_EXPORT"
            return
            ;;
        fish)
            item "Needs you" "PATH: $BIN_DIR isn't on your PATH." "Run: fish_add_path ~/.local/bin"
            return
            ;;
        *)
            item "Needs you" "PATH: $BIN_DIR isn't on your PATH, and your shell ($shell) doesn't read $ZPROFILE." \
                "Add $BIN_DIR to PATH in your shell's profile."
            return
            ;;
    esac
    if {
        if [ -s "$ZPROFILE" ] && [ -n "$(tail -c 1 "$ZPROFILE")" ]; then printf '\n' >>"$ZPROFILE"; fi &&
            printf '%s\n' "$PATH_LINE" >>"$ZPROFILE"
    } 2>/dev/null; then
        item "Needs you" "PATH: added $BIN_DIR to your PATH in $ZPROFILE." "Open a new terminal window to use the redline command."
    else
        item "Needs you" "PATH: couldn't write $ZPROFILE, so $BIN_DIR isn't on your PATH." \
            "Add this line to your shell profile, then open a new terminal window: $PATH_EXPORT"
    fi
}

# Copies the command from the build output; never from the app bundle, where macOS stops a copy.
install_command() {
    step "Installing the redline command"
    mkdir -p "$BIN_DIR" || stop "Couldn't create $BIN_DIR." "Check that you can write to $HOME."
    TMP_BIN="$BIN_DIR/.redline.new.$$"
    if ! { cp "$BUILT" "$TMP_BIN" && chmod 755 "$TMP_BIN" && mv -f "$TMP_BIN" "$COMMAND"; }; then
        stop "Couldn't copy the redline command to $COMMAND." "Check that you can write to $BIN_DIR."
    fi
    TMP_BIN=""
    item "Done" "Command: $COMMAND"
    add_to_path
}

install_app() {
    local output
    step "Building and installing Redline.app"
    if ! output="$(/bin/zsh "$SOURCE/scripts/build-hub-app.sh" "$HOME/Applications" 2>&1)"; then
        printf '%s\n' "$output" >>"$LOG"
        show_log_errors
        stop "Building Redline.app failed. The full log is $LOG." "Fix the error above; an Xcode update or opening Xcode once often does."
    fi
    printf '%s\n' "$output" >>"$LOG"
    case "$output" in
        *"Signed ad hoc"*) item "Done" "App: $APP (signed ad hoc, so macOS may ask again for what you allowed it after each update)" ;;
        *) item "Done" "App: $APP" ;;
    esac
}

# Runs redline setup: the claude command check and the Codex hook. With someone to ask it can run
# claude update and claude auth login; otherwise it only says what's left.
run_setup() {
    local status output="" file
    step "Setting up Claude Code and Codex"
    if can_ask; then
        "$COMMAND" setup </dev/tty
        status=$?
    else
        output="$("$COMMAND" setup --no-input 2>&1)"
        status=$?
        printf '%s\n' "$output" | tee -a "$LOG"
    fi
    if [ "$status" -eq 0 ]; then
        SETUP_OK=true
        item "Done" "Setup: ran redline setup"
        return
    fi
    file="$(failed_settings_file "$output")"
    if [ -z "$file" ] && [ -d "$HOME/.codex" ] && ! grep -q 'Report delivery' "$HOME/.codex/hooks.json" 2>/dev/null; then
        file="$HOME/.codex/hooks.json"
    fi
    item "Needs you" "Setup: redline setup couldn't update ${file:-a settings file (named in its output above)}." \
        "Fix or move that file, then run: $COMMAND setup"
}

# The earlier version, Agentic Debugging, would run a second hub next to Redline. Its app goes;
# its command goes once setup has moved every hook over to redline.
remove_old_install() {
    local removed=""
    if stop_app "$OLD_APP"; then removed="stopped it"; fi
    if [ -e "$OLD_APP" ] && rm -rf "$OLD_APP"; then removed="${removed:+$removed, }removed $OLD_APP"; fi
    if [ -e "$OLD_COMMAND" ]; then
        if ! $SETUP_OK; then
            item "Skipped" "Earlier version: kept $OLD_COMMAND until redline setup succeeds, because hooks may still run it"
        elif rm -f "$OLD_COMMAND"; then
            removed="${removed:+$removed, }removed $OLD_COMMAND"
        fi
    fi
    if [ -n "$removed" ]; then item "Done" "Earlier version (Agentic Debugging): $removed"; fi
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

# Writes the login item's property list to $1. It opens Redline in the background at login, and
# names Redline, not open, in System Settings > General > Login Items.
write_launch_agent_plist() {
    rm -f "$1"
    plutil -create xml1 "$1" &&
        plutil -insert Label -string "$LABEL" "$1" &&
        plutil -insert AssociatedBundleIdentifiers -string "$LABEL" "$1" &&
        plutil -insert ProgramArguments -json '["/usr/bin/open","-g"]' "$1" &&
        plutil -insert ProgramArguments -string "$APP" -append "$1" &&
        plutil -insert RunAtLoad -bool true "$1"
}

start_redline() {
    local domain loaded=false try pattern
    if $NO_START; then
        item "Skipped" "Login item and start (--no-start). To start Redline, run: open $APP"
        return
    fi
    step "Opening Redline at login and now"
    domain="gui/$(id -u)"
    mkdir -p "$(dirname "$LAUNCH_AGENT")"
    # Written next to the report, not in LaunchAgents, so an interrupted run leaves nothing there.
    TMP_PLIST="$DATA/launch-agent.plist.new.$$"
    write_launch_agent_plist "$TMP_PLIST" >>"$LOG" 2>&1 || stop "Couldn't write the login item." "Read $LOG for what went wrong."
    if cmp -s "$TMP_PLIST" "$LAUNCH_AGENT" && launchctl print "$domain/$LABEL" >/dev/null 2>&1; then
        item "Done" "Login item: Redline opens at login ($LAUNCH_AGENT)"
    else
        launchctl bootout "$domain/$LABEL" >/dev/null 2>&1 || true
        mv -f "$TMP_PLIST" "$LAUNCH_AGENT" || stop "Couldn't write $LAUNCH_AGENT." "Check that you can write to $HOME/Library/LaunchAgents."
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
    rm -f "$TMP_PLIST"
    TMP_PLIST=""

    open -g "$APP" >>"$LOG" 2>&1
    pattern="$(app_processes "$APP")"
    for try in 1 2 3 4 5 6 7 8 9 10; do
        if pgrep -f "$pattern" >/dev/null 2>&1; then
            item "Done" "Redline is running: its icon is in the menu bar"
            return
        fi
        sleep 1
    done
    item "Needs you" "Redline didn't start." "Run: open $APP" "If it still doesn't start, its log is $DATA/hub/hub.log"
}

check_codex() {
    if grep -q 'Report delivery' "$HOME/.codex/hooks.json" 2>/dev/null; then
        item "Needs you" "Codex: if you haven't already, trust the Report delivery hook. Codex runs a new hook only after you trust it." \
            "In Codex, open /hooks and trust \"Report delivery\"."
    elif [ -d "$HOME/.codex" ]; then
        item "Needs you" "Codex: the Report delivery hook isn't in $HOME/.codex/hooks.json (see the Setup line)." \
            "Fix or move that file, then run: $COMMAND setup" "Then in Codex, open /hooks and trust \"Report delivery\"."
    elif [ -x /opt/homebrew/bin/codex ] || [ -x /usr/local/bin/codex ] || [ -d /Applications/Codex.app ] || [ -d /Applications/ChatGPT.app/Contents/Resources/codex-cli ]; then
        item "Skipped" "Codex: installed but not used yet (no $HOME/.codex), so no hook was added. After you first use it, run: $COMMAND setup"
    else
        item "Skipped" "Codex: not used on this Mac"
    fi
}

install() {
    local summary
    move_old_data
    start_log
    preflight
    find_source
    build_command
    install_command
    install_app
    run_setup
    remove_old_install
    check_claude
    register_mcp
    start_redline
    check_codex
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

# Takes Redline's hooks out of the agents' settings: with redline remove, or without it when the
# command is already gone, so no hook is left running a missing command.
remove_hooks() {
    local output status file result found=false
    if [ -x "$COMMAND" ]; then
        output="$("$COMMAND" remove 2>&1)"
        status=$?
        printf '%s\n' "$output" >>"$LOG"
        if [ "$status" -eq 0 ]; then
            item "Done" "Hooks: removed Redline's hooks; other hooks stay"
        else
            file="$(failed_settings_file "$output")"
            item "Needs you" "Hooks: couldn't update ${file:-a settings file} (see $LOG)." \
                "Fix that file, then run: $COMMAND remove" "Or delete the hooks whose command ends in \"redline hook ...\" by hand."
        fi
        return
    fi
    for file in "$HOME/.codex/hooks.json" "$HOME/.claude/settings.json" "$HOME/.cursor/hooks.json"; do
        grep -qE "/(redline|agentic-debugging)' hook " "$file" 2>/dev/null || continue
        found=true
        result="$(remove_hooks_from "$file")"
        if [ "$result" = "removed" ]; then
            item "Done" "Hooks: removed Redline's hooks from $file; other hooks stay"
        else
            item "Needs you" "Hooks: couldn't remove Redline's hooks from $file (${result:-failed})." \
                "Delete the hooks whose command ends in \"redline hook ...\" by hand."
        fi
    done
    $found || item "Skipped" "Hooks: none of Redline's were found"
}

uninstall() {
    local domain have tmp rc
    start_log
    step "Removing Redline"

    remove_hooks

    find_claude
    for have in redline agentic-debugging; do
        [ -n "$(mcp_entry "$have")" ] || continue
        if [ -z "$CLAUDE" ]; then
            item "Needs you" "MCP server: the claude command isn't installed, so the $have entry is still in ~/.claude.json." \
                "Delete \"$have\" under \"mcpServers\" in ~/.claude.json, or run claude mcp remove --scope user $have once claude is installed."
        elif "$CLAUDE" mcp remove --scope user "$have" >>"$LOG" 2>&1; then
            item "Done" "MCP server: removed $have from Claude Code"
        else
            item "Needs you" "MCP server: couldn't remove $have (see $LOG)." "Run: claude mcp remove --scope user $have"
        fi
    done

    if [ -f "$LAUNCH_AGENT" ]; then
        if $NO_START; then
            rm -f "$LAUNCH_AGENT"
            item "Done" "Login item: deleted $LAUNCH_AGENT; launchd left alone (--no-start)"
        else
            domain="gui/$(id -u)"
            # Only the service this home folder's app runs, never one with the same label for another.
            if launchctl print "$domain/$LABEL" 2>/dev/null | grep -qF "$APP"; then
                launchctl bootout "$domain/$LABEL" >>"$LOG" 2>&1 || true
            fi
            rm -f "$LAUNCH_AGENT"
            item "Done" "Login item: removed"
        fi
    fi

    if stop_app "$APP"; then item "Done" "Stopped Redline"; fi

    if [ -e "$APP" ] || [ -e "$COMMAND" ]; then
        rm -rf "$APP"
        rm -f "$COMMAND"
        item "Done" "Removed $APP and $COMMAND"
    else
        item "Skipped" "The app and the command were already removed"
    fi

    if grep -qxF "$PATH_LINE" "$ZPROFILE" 2>/dev/null; then
        tmp="$ZPROFILE.redline.$$"
        TMP_ZPROFILE="$tmp"
        grep -vxF "$PATH_LINE" "$ZPROFILE" >"$tmp"
        rc=$?
        # Only when grep read the whole file and the copy back works; cat, not mv, so a
        # ~/.zprofile that is a link stays one.
        if [ "$rc" -le 1 ] && cat "$tmp" >"$ZPROFILE"; then
            item "Done" "PATH: removed the installer's line from $ZPROFILE"
        else
            item "Needs you" "PATH: couldn't edit $ZPROFILE." "Delete the line ending in \"# Added by the Redline installer\"."
        fi
        rm -f "$tmp"
        TMP_ZPROFILE=""
    fi

    rm -rf "$CACHE"
    item "Done" "Kept your reports in $DATA. Delete that folder to remove them."
    if [ -d "$OLD_DATA" ]; then item "Done" "Kept the earlier version's reports in $OLD_DATA"; fi
    if [ -e "$HOME/.codex/hooks.json.before-redline" ] || [ -e "$HOME/.claude/settings.json.before-redline" ]; then
        item "Done" "Kept the settings backups from Redline's first setup (the .before-redline files in ~/.codex and ~/.claude)"
    fi
    finish "Redline uninstall checklist" "Redline is removed. In your app, remove the .redline() line and the Redline package."
}

main() {
    local argument
    for argument in "$@"; do
        case "$argument" in
            uninstall) ACTION="uninstall" ;;
            --no-start) NO_START=true ;;
            --no-input) NO_INPUT=true ;;
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
    # Before anything is written: files made by root in the home folder would break later runs.
    if [ "$(id -u)" -eq 0 ]; then
        printf 'The installer is running as root. Run it as yourself, without sudo.\n' >&2
        exit 1
    fi
    case "${HOME:-}" in
        /?*) ;;
        *)
            printf 'HOME must be your home folder, as an absolute path; it is "%s".\n' "${HOME:-}" >&2
            exit 1
            ;;
    esac
    if [ ! -d "$HOME" ]; then
        printf 'HOME (%s) is not a folder.\n' "$HOME" >&2
        exit 1
    fi
    # Coding agents and CI may run commands in a terminal that nobody is watching.
    if [ -n "${REDLINE_NO_INPUT:-}" ] || [ -n "${CLAUDECODE:-}" ] || [ -n "${CODEX_SANDBOX:-}" ] ||
        [ -n "${CODEX_THREAD_ID:-}" ] || [ -n "${CI:-}" ]; then
        NO_INPUT=true
    fi
    set_paths
    trap cleanup EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    if [ "$ACTION" = "uninstall" ]; then uninstall; else install; fi
    exit 0
}

# Standard input is closed for everything the installer runs: piped from curl, it is the script.
main "$@" </dev/null
