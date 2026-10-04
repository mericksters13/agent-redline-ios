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
MOVE_OLD_DATA=false
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
Through curl: curl -fsSL https://raw.githubusercontent.com/mericksters13/agent-redline-ios/main/install.sh \
  -o "${TMPDIR:-/tmp}/redline-install.sh" && bash "${TMPDIR:-/tmp}/redline-install.sh"

Run on its own, outside a checkout or the npm package, it downloads the source from REDLINE_REPO (default
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
    mkdir -p "$(dirname "$REPORT")" 2>/dev/null || return 0
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
    local folder
    folder="$(dirname "$LOG")"
    mkdir -p "$folder" || stop_early "Couldn't create $folder." "Check that you can write to $(dirname "$folder")."
    printf 'Redline installer, %s, %s\n' "$ACTION" "$(date)" >"$LOG" ||
        stop_early "Couldn't write $LOG." "Check that you own that folder: ls -ld \"$folder\""
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

# Stops the app at $1 if it is running and waits three seconds for it to go. Returns 0 when it
# stopped, 1 when it wasn't running and 2 when it is still running.
stop_app() {
    local pattern try
    pattern="$(app_processes "$1")"
    pkill -TERM -f "$pattern" 2>/dev/null || return 1
    for try in 1 2 3 4 5 6 7 8 9 10; do
        pgrep -f "$pattern" >/dev/null || return 0
        sleep 0.3
    done
    pgrep -f "$pattern" >/dev/null && return 2
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

# Claude Code's settings file, which holds its user-scoped MCP servers.
claude_config() {
    printf '%s' "${CLAUDE_CONFIG_DIR:-$HOME}/.claude.json"
}

# The command line of Claude Code's user-scoped MCP server named $1, or nothing. A server that
# runs no command, such as one reached by URL, gives its URL or type instead. Read from the
# settings file, because "claude mcp get" starts the server to check it. Fails when the file is
# there but can't be read or isn't valid JSON, so a broken file isn't taken for a missing entry.
mcp_entry() {
    local config
    config="$(claude_config)"
    [ -f "$config" ] || return 0
    /usr/bin/osascript -l JavaScript - "$config" "$1" 2>/dev/null <<'JS'
function run(argv) {
    ObjC.import("Foundation");
    var text = $.NSString.stringWithContentsOfFileEncodingError(argv[0], $.NSUTF8StringEncoding, null);
    if (text.isNil()) throw new Error("unreadable");
    var server = (JSON.parse(text.js).mcpServers || {})[argv[1]];
    if (!server) return "";
    if (typeof server.command !== "string") return String(server.url || server.type || "a server with no command");
    return [server.command].concat(server.args || []).join(" ");
}
JS
}

# Whether the MCP server command line $2, of the entry named $1, is one Redline added: the redline
# command's mcp, or the earlier version's agentic-debugging mcp. Another tool's server with the
# same name is not Redline's, so the installer neither replaces nor removes it.
mcp_entry_is_ours() {
    case "$1:$2" in
        "redline:$COMMAND mcp" | "redline:$COMMAND mcp "*) return 0 ;;
        "agentic-debugging:agentic-debugging mcp" | "agentic-debugging:agentic-debugging mcp "*) return 0 ;;
        "agentic-debugging:"*"/agentic-debugging mcp" | "agentic-debugging:"*"/agentic-debugging mcp "*) return 0 ;;
    esac
    return 1
}

# Removes Redline's hooks from the agent settings file $1 without the redline command, for
# uninstall, as redline remove would: hooks that run the command at $2, or the earlier version's
# agentic-debugging with a hook's arguments, go; groups left empty go; everything else stays, even
# another tool's command named redline. Prints removed, unchanged, unreadable or unwritable.
remove_hooks_from() {
    /usr/bin/osascript -l JavaScript - "$1" "$2" 2>/dev/null <<'JS'
function run(argv) {
    ObjC.import("Foundation");
    var text = $.NSString.stringWithContentsOfFileEncodingError(argv[0], $.NSUTF8StringEncoding, null);
    if (text.isNil()) return "unchanged";
    var settings;
    try { settings = JSON.parse(text.js); } catch (error) { return "unreadable"; }
    // The same agents and events as earlierHookArguments in Sources/RedlineTool/AgentSettings.swift.
    var agents = ["claude", "codex", "cursor"], events = ["start", "prompt", "wait", "built", "stop", "end"];
    function ours(hook) {
        if (!hook || typeof hook.command !== "string") return false;
        var match = /^'((?:[^']|'\\'')*)' hook ([\s\S]*)$/.exec(hook.command);
        if (!match) return false;
        var path = match[1].replace(/'\\''/g, "'"), args = match[2].split(" ");
        if (path === argv[1]) return true;
        return path.split("/").pop() === "agentic-debugging" && args.length === 2 &&
            agents.indexOf(args[0]) >= 0 && events.indexOf(args[1]) >= 0;
    }
    var hooks = settings && settings.hooks, changed = false;
    if (!hooks || typeof hooks !== "object") return "unchanged";
    Object.keys(hooks).forEach(function (event) {
        if (!Array.isArray(hooks[event])) return;
        var kept = [];
        hooks[event].forEach(function (entry) {
            if (ours(entry)) { changed = true; return; }
            if (entry && Array.isArray(entry.hooks)) {
                var others = entry.hooks.filter(function (hook) { return !ours(hook); });
                if (others.length !== entry.hooks.length) changed = true;
                if (others.length === 0) return;
                entry.hooks = others;
            }
            kept.push(entry);
        });
        if (kept.length) hooks[event] = kept; else delete hooks[event];
    });
    if (!changed) return "unchanged";
    if (Object.keys(hooks).length === 0) delete settings.hooks;
    var out = $.NSString.alloc.initWithUTF8String(JSON.stringify(settings, null, 2) + "\n");
    return out.writeToFileAtomicallyEncodingError(argv[0], true, $.NSUTF8StringEncoding, null) ? "removed" : "unwritable";
}
JS
}

# An earlier version kept its reports, paired phones and chats in another folder. They move to
# Redline's folder only once the new command and app are installed, so a run that stops before
# then leaves the earlier version working with its data; until then the log and the checklist
# are kept in the cache folder (see install). A hub of the earlier version still running is
# stopped first. The pid in hub.pid counts only while that process has the file open: a running
# hub holds its lock on it, and a file left by a hub that crashed may name a pid macOS has given
# to another app.
move_old_data() {
    local pid pid_file try pending_log="$LOG" pending_report="$REPORT"
    $MOVE_OLD_DATA || return 0
    step "Moving the earlier version's reports"
    stop_app "$OLD_APP"
    if [ $? -eq 2 ]; then
        stop "The earlier version (Agentic Debugging) is still running." "Quit it from its menu bar icon."
    fi
    pid_file="$OLD_DATA/hub/hub.pid"
    pid="$(tr -d '[:space:]' 2>/dev/null <"$pid_file")"
    case "$pid" in
        '' | *[!0-9]*) ;;
        *)
            if lsof -t -a -p "$pid" -- "$pid_file" 2>/dev/null | grep -qx "$pid"; then
                kill -TERM "$pid" 2>/dev/null
                for try in 1 2 3 4 5 6 7 8 9 10; do
                    kill -0 "$pid" 2>/dev/null || break
                    sleep 0.3
                done
                if kill -0 "$pid" 2>/dev/null; then
                    stop "The hub of the earlier version (Agentic Debugging, pid $pid) is still running." "Quit it: kill $pid"
                fi
            fi
            ;;
    esac
    if [ -e "$DATA" ] || ! { mkdir -p "$(dirname "$DATA")" && mv "$OLD_DATA" "$DATA"; } >>"$LOG" 2>&1; then
        stop "Couldn't move the earlier version's reports from $OLD_DATA to $DATA." \
            "Check that you can write to $HOME/Library/Application Support, and that $DATA doesn't exist."
    fi
    MOVE_OLD_DATA=false
    LOG="$DATA/install.log"
    REPORT="$DATA/install-report.txt"
    mv -f "$pending_log" "$LOG" 2>/dev/null || cat "$pending_log" >>"$LOG" 2>/dev/null
    rm -f "$pending_log" "$pending_report"
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
    local output start=""
    step "Building and installing Redline.app"
    # With --no-start, a running Redline is stopped for the update and not opened again.
    if $NO_START; then start="--no-start"; fi
    if ! output="$(/bin/zsh "$SOURCE/scripts/build-hub-app.sh" "$HOME/Applications" ${start:+"$start"} 2>&1)"; then
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
    local removed="" status
    stop_app "$OLD_APP"
    status=$?
    if [ "$status" -eq 2 ]; then
        item "Needs you" "Earlier version (Agentic Debugging): it is still running, so $OLD_APP stays." \
            "Quit it from its menu bar icon, then run the installer again."
    else
        if [ "$status" -eq 0 ]; then removed="stopped it"; fi
        if remove_old_file "$OLD_APP"; then removed="${removed:+$removed, }removed $OLD_APP"; fi
    fi
    if [ -e "$OLD_COMMAND" ] || [ -L "$OLD_COMMAND" ]; then
        if ! $SETUP_OK; then
            item "Skipped" "Earlier version: kept $OLD_COMMAND until redline setup succeeds, because hooks may still run it"
        elif remove_old_file "$OLD_COMMAND"; then
            removed="${removed:+$removed, }removed $OLD_COMMAND"
        fi
    fi
    if [ -n "$removed" ]; then item "Done" "Earlier version (Agentic Debugging): $removed"; fi
    # Moved only into a new folder (see install), so it stays when Redline's folder already existed.
    if [ -d "$OLD_DATA" ]; then
        item "Needs you" "Earlier version: its reports, paired phones and chats stay in $OLD_DATA, because $DATA already existed. Redline reads only $DATA." \
            "Pair your phone again from Redline's menu if it was paired with the earlier version." "Delete $OLD_DATA once you no longer need its reports."
    fi
}

# Deletes the earlier version's file or folder at $1. Returns 0 when it was there and is gone, and
# 1 when it wasn't there or couldn't be deleted, which adds a Needs you item: a leftover app could
# be opened again and run its hub next to Redline's.
remove_old_file() {
    [ -e "$1" ] || [ -L "$1" ] || return 1
    rm -rf "$1" >>"$LOG" 2>&1
    if [ -e "$1" ] || [ -L "$1" ]; then
        item "Needs you" "Earlier version (Agentic Debugging): couldn't delete $1 (see $LOG)." \
            "Check its owner, permissions and flags with ls -ldO ${1// /\\ }, then delete it."
        return 1
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
    local old have note=""
    [ -n "$CLAUDE" ] || return 0
    step "Adding Redline's MCP server to Claude Code"
    if ! old="$(mcp_entry agentic-debugging)" || ! have="$(mcp_entry redline)"; then
        item "Needs you" "MCP server: couldn't read $(claude_config) as JSON, so Redline's MCP server wasn't added." \
            "Fix that file, then run the installer again."
        return
    fi
    if [ -n "$old" ] && mcp_entry_is_ours agentic-debugging "$old"; then
        if "$CLAUDE" mcp remove --scope user agentic-debugging >>"$LOG" 2>&1; then
            note="; removed the old agentic-debugging entry"
        else
            item "Needs you" "MCP server: couldn't remove the earlier version's agentic-debugging entry, which runs a command that is gone (see $LOG)." \
                "Run: claude mcp remove --scope user agentic-debugging"
        fi
    fi
    if [ "$have" = "$COMMAND mcp" ]; then
        item "Done" "MCP server: Claude Code already runs redline mcp$note"
        return
    fi
    if [ -n "$have" ] && ! mcp_entry_is_ours redline "$have"; then
        item "Needs you" "MCP server: Claude Code already has another MCP server named redline, which runs $have, so Redline's wasn't added." \
            "If you no longer need it, run: claude mcp remove --scope user redline" "Then run the installer again."
        return
    fi
    [ -z "$have" ] || "$CLAUDE" mcp remove --scope user redline >>"$LOG" 2>&1
    if "$CLAUDE" mcp add --scope user redline -- "$COMMAND" mcp >>"$LOG" 2>&1; then
        item "Done" "MCP server: added to Claude Code (user scope) as redline$note"
    else
        item "Needs you" "MCP server: couldn't add it to Claude Code (see $LOG)." "Run: claude mcp add --scope user redline -- $COMMAND mcp"
    fi
}

# Writes the login item's property list to $1. It starts Redline's own executable at login, which
# opens in the background as a menu bar app, so System Settings > General > Login Items names it
# after Redline, not after open. The executable is signed with the app, which
# AssociatedBundleIdentifiers needs to show the item as the app. launchd gives it only the system's
# folders on PATH, so the folder of the claude command found here goes first: installed under a
# Node version manager, claude (and the node it runs) is only there.
write_launch_agent_plist() {
    rm -f "$1"
    plutil -create xml1 "$1" &&
        plutil -insert Label -string "$LABEL" "$1" &&
        plutil -insert AssociatedBundleIdentifiers -string "$LABEL" "$1" &&
        plutil -insert ProgramArguments -array "$1" &&
        plutil -insert ProgramArguments -string "$APP/Contents/MacOS/redline" -append "$1" &&
        plutil -insert RunAtLoad -bool true "$1" || return 1
    [ -n "$CLAUDE" ] || return 0
    plutil -insert EnvironmentVariables -dictionary "$1" &&
        plutil -insert EnvironmentVariables.PATH -string "$(dirname "$CLAUDE"):/usr/bin:/bin:/usr/sbin:/sbin" "$1"
}

start_redline() {
    local domain loaded=false opened=false try pattern
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

    # A login item just loaded starts Redline by itself. Otherwise, or when it hasn't after three
    # seconds, open starts it.
    pattern="$(app_processes "$APP")"
    for try in 1 2 3 4 5 6 7 8 9 10; do
        if pgrep -f "$pattern" >/dev/null 2>&1; then
            item "Done" "Redline is running: its icon is in the menu bar"
            return
        fi
        if ! $opened && { ! $loaded || [ "$try" -ge 4 ]; }; then
            open -g "$APP" >>"$LOG" 2>&1
            opened=true
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
    # The earlier version's data moves only after the build (move_old_data). Until then nothing is
    # written to Redline's folder, because the move needs it not to exist.
    if [ -d "$OLD_DATA" ] && [ ! -e "$DATA" ]; then
        MOVE_OLD_DATA=true
        LOG="$CACHE/install.log"
        REPORT="$CACHE/install-report.txt"
    fi
    start_log
    preflight
    find_source
    build_command
    install_command
    install_app
    move_old_data
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

# Takes Redline's hooks out of the agents' settings: with redline remove when the command is
# installed, then by scanning the settings files, so no hook is left running a missing command.
# The scan also catches hooks that an older installed command doesn't know about, such as Cursor's,
# and runs even when redline remove failed without naming the file. Returns 1 when hooks may be
# left, because the uninstall deletes the command they run.
remove_hooks() {
    local output status file result rc failed="" delegated=false unexplained=false found=false kept=false
    if [ -x "$COMMAND" ]; then
        delegated=true
        output="$("$COMMAND" remove 2>&1)"
        status=$?
        printf '%s\n' "$output" >>"$LOG"
        if [ "$status" -eq 0 ]; then
            item "Done" "Hooks: removed Redline's hooks; other hooks stay"
        else
            failed="$(failed_settings_file "$output")"
            if [ -n "$failed" ]; then
                kept=true
                item "Needs you" "Hooks: couldn't update $failed (see $LOG)." \
                    "Fix that file, then run the same command again." "Or delete the hooks whose command ends in \"redline hook ...\" by hand."
            else
                # Reported after the scan, which names any file it couldn't change.
                unexplained=true
            fi
        fi
    fi
    for file in "$HOME/.codex/hooks.json" "$HOME/.claude/settings.json" "$HOME/.cursor/hooks.json"; do
        [ "$file" != "$failed" ] && [ -e "$file" ] || continue
        grep -qE "/(redline|agentic-debugging)' hook " "$file" 2>/dev/null
        rc=$?
        [ "$rc" -ne 1 ] || continue
        if [ "$rc" -ne 0 ]; then
            found=true
            kept=true
            item "Needs you" "Hooks: couldn't read $file, so Redline's hooks may still be in it." \
                "Check its owner and permissions with ls -lO $file, then run the same command again."
            continue
        fi
        result="$(remove_hooks_from "$file" "$COMMAND")"
        # Unchanged: the hooks there are another tool's, such as another command named redline.
        [ "$result" != "unchanged" ] || continue
        found=true
        if [ "$result" = "removed" ]; then
            item "Done" "Hooks: removed Redline's hooks from $file; other hooks stay"
        else
            kept=true
            item "Needs you" "Hooks: couldn't remove Redline's hooks from $file (${result:-failed})." \
                "Delete the hooks whose command ends in \"redline hook ...\" by hand."
        fi
    done
    if $unexplained && ! $found; then
        kept=true
        item "Needs you" "Hooks: redline remove failed (see $LOG), and the installer found none of Redline's hooks to take out itself." \
            "Read $LOG for the reason, then run the same command again." \
            "Or delete the hooks whose command ends in \"redline hook ...\" by hand."
    fi
    $found || $delegated || item "Skipped" "Hooks: none of Redline's were found"
    ! $kept
}

uninstall() {
    local domain name have tmp rc artifact left=""
    start_log
    step "Removing Redline"

    remove_hooks || left="${left:+$left and }Redline's hooks"

    find_claude
    for name in redline agentic-debugging; do
        if ! have="$(mcp_entry "$name")"; then
            left="${left:+$left and }Redline's MCP server entries"
            item "Needs you" "MCP server: couldn't read $(claude_config) as JSON, so Redline's entries may still be in it." \
                "Fix that file, then run the same command again."
            break
        fi
        [ -n "$have" ] || continue
        if ! mcp_entry_is_ours "$name" "$have"; then
            item "Skipped" "MCP server: kept the $name entry, which runs $have, not Redline"
            continue
        fi
        if [ -z "$CLAUDE" ]; then
            left="${left:+$left and }the $name MCP server entry"
            item "Needs you" "MCP server: the claude command isn't installed, so the $name entry is still in $(claude_config)." \
                "Delete \"$name\" under \"mcpServers\" in that file, or run claude mcp remove --scope user $name once claude is installed."
        elif "$CLAUDE" mcp remove --scope user "$name" >>"$LOG" 2>&1; then
            item "Done" "MCP server: removed $name from Claude Code"
        else
            left="${left:+$left and }the $name MCP server entry"
            item "Needs you" "MCP server: couldn't remove $name (see $LOG)." "Run: claude mcp remove --scope user $name"
        fi
    done

    if [ -f "$LAUNCH_AGENT" ] || [ -L "$LAUNCH_AGENT" ]; then
        if ! $NO_START; then
            domain="gui/$(id -u)"
            # Only the service this home folder's app runs, never one with the same label for another.
            if launchctl print "$domain/$LABEL" 2>/dev/null | grep -qF "$APP"; then
                launchctl bootout "$domain/$LABEL" >>"$LOG" 2>&1 || true
            fi
        fi
        rm -f "$LAUNCH_AGENT" >>"$LOG" 2>&1
        if [ -e "$LAUNCH_AGENT" ] || [ -L "$LAUNCH_AGENT" ]; then
            left="${left:+$left and }$LAUNCH_AGENT"
            item "Needs you" "Login item: couldn't delete $LAUNCH_AGENT (see $LOG)." \
                "Check its owner, permissions and flags with ls -ldO $LAUNCH_AGENT, then delete it."
        elif $NO_START; then
            item "Done" "Login item: deleted $LAUNCH_AGENT; launchd left alone (--no-start)"
        else
            item "Done" "Login item: removed"
        fi
    fi

    stop_app "$APP"
    case $? in
        0) item "Done" "Stopped Redline" ;;
        2)
            left="${left:+$left and }a running Redline"
            item "Needs you" "Redline is still running and didn't stop when asked." "Quit it from its menu bar icon."
            ;;
    esac

    for artifact in "$APP" "$COMMAND"; do
        if [ ! -e "$artifact" ] && [ ! -L "$artifact" ]; then
            item "Skipped" "$artifact was already removed"
            continue
        fi
        rm -rf "$artifact" >>"$LOG" 2>&1
        if [ -e "$artifact" ] || [ -L "$artifact" ]; then
            left="${left:+$left and }$artifact"
            item "Needs you" "Couldn't delete $artifact (see $LOG)." \
                "Check its owner, permissions and flags with ls -ldO $artifact, then delete it."
        else
            item "Done" "Removed $artifact"
        fi
    done

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
    if [ -n "$left" ]; then
        finish "Redline uninstall checklist" "Redline is not fully removed; still there: $left. See Needs you above, then run the same command again."
        exit 1
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
