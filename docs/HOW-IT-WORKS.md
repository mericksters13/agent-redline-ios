# How Redline works

This page has the details behind the [README](../README.md). You don't need any of it to use Redline.

## Which apps Redline takes reports for

- The apps of open Claude Code chats. Redline finds these chats from the session files Claude Code keeps in `~/.claude/sessions`. Each Claude Code chat started after the install also runs `redline mcp`, which opens Redline if it isn't running.
- The apps of Codex chats. A Codex chat registers through the "Report delivery" hook each time you send it a message.
- Every app a chat worked on before. Its reports still arrive after the chat closes, and can start a new chat.
- Apps given with `--app` to `redline hub` or `redline app`.

Redline reads bundle IDs from the app targets of the Xcode projects in a chat's folder, up to four folders down, in every build configuration. Extensions, watch apps and test bundles are left out. Without an Xcode project, it reads the bundle IDs written in an XcodeGen `project.yml`.

## How the phone finds the Mac

**iPhone.** Redline writes `hub.json` into each app's data container over Xcode's device link (`devicectl device copy to`). The file holds:

- the Mac's IPv4 addresses on Wi-Fi and Ethernet (not VPN links), its `.local` name and port 47361
- the phone's ID, which an app can't find out on its own
- a token for that phone and app

Redline looks for paired phones and the apps installed on them when it starts, when the set of apps it takes reports for changes, and every 30 minutes. At each look it writes the file again, in case an app was reinstalled. It also writes it again when the Mac's address changes. An app installed on a phone after the last look waits for the next one.

A phone that can't be reached is tried again after 30 seconds, then after waits that double up to 5 minutes. When a phone announces on the network that it woke, Redline tries again at once.

**Simulator.** A simulator app's files are ordinary files on the Mac. Redline writes `hub.json` with `127.0.0.1`, which the app uses only to ask for the chats in Send to. It watches the app's folder with file system events, copies each finished report out of it, and marks the report delivered. Every install changes the app's folder: a first install or a reinstall makes a new one, and installing over a build, as Xcode's Run does, renames it, `hub.json` and all. Redline also watches the folders that list simulators and their apps' folders, so as an install happens it writes `hub.json` into a new folder and moves its watch to the new or renamed one.

## How a report reaches the Mac

The app sends every report the Mac hasn't confirmed when it launches, each time it comes back to the foreground, and with each Send. On an iPhone, one connection carries them, one line of JSON per message:

1. The app says who it is, and Redline proves it holds the app's token.
2. The app offers its reports, with its own proof.
3. Redline answers which reports it wants and which it already has.
4. The app sends each wanted report's files.
5. Redline confirms what it now has.

Each proof is an HMAC of both sides' random values for that connection, keyed with the token. So the token never crosses the network, and a proof can't be used again. The connection isn't encrypted, so the report files cross the network as they are.

## How a chat is chosen

The README says [where reports go](../README.md#where-reports-go). Underneath it:

- **The build's worktree.** At compile time, `.redline()` records the path of the source file that calls it. Redline walks up from that path to the folder that holds `.git`, and uses that worktree only if it builds the report's app. Without it, a report with no pick, or with a New chat pick, waits in the inbox. A pick of a specific chat still goes to that chat.
- **The chats that work on an app** are the open Claude Code chats, and the Codex chats used in the last 14 days that aren't archived, whose folder builds the app. The phone shows up to 15 Codex chats.
- **Picks.** The phone saves your pick for the worktree the build came from. A New chat pick remembers the chat it started, and later reports with that pick go to it while its worktree exists.
- **The agent for a new chat.** With no pick, Redline uses the agent last used on this app, or else the first agent that can start a chat. An agent can start chats when its command, `claude` or `codex`, is installed and the build's repository has a main branch: origin's default branch, or a local `main` or `master`.
- **Waiting chats.** A Claude Code chat waiting in `wait_for_message`, or a `redline wait`, takes a report with no pick as soon as it arrives, before Redline chooses a chat.

## How a new chat starts

1. Redline fetches the main branch from the repository's origin, asking origin which branch that is when the clone doesn't know. Without a network it uses the last fetch. Without an origin, it uses a local `main` or `master`.
2. It makes a git worktree from that branch, on a branch named `report/<report ID>`. A Claude Code chat's worktree goes in `.claude/worktrees` in the repository, which Redline adds to the repository's own exclude file. A Codex chat's worktree goes in `~/.codex/worktrees`.
3. It starts the chat:
   - **Codex:** `codex exec --sandbox read-only`, with the report and its snapshots. Then the chat opens in the Codex app, or with `codex resume` in Terminal without the app.
   - **Claude Code:** Redline copies the report into the worktree's `.redline` folder, which git ignores, so the chat reads the snapshots without asking. It runs `claude -p` in plan mode with a short first prompt. Then `claude --desktop --resume` opens the chat in the Claude app, or `claude --resume` in Terminal without the app, and the report goes in as a message. If the chat doesn't open within a minute, the report goes in with `claude -p --resume` in plan mode instead.

## How a chat gets the report

- **Claude Code.** Each Claude Code chat listens on a socket for messages from your other chats. Redline sends the report's text there. New and closed chats need the `claude` command signed in. Until it is, their reports wait in the inbox, and Redline checks again on its own.
- **Codex.** Redline asks the Codex app, or the ChatGPT app when Codex comes inside it, to start a turn in the chat. If the app doesn't take the report, Redline addresses it to that chat, and the "Report delivery" hook, on `UserPromptSubmit`, puts it in with your next message there.

A report no chat was chosen for waits in the inbox. It goes to a Claude Code chat that calls `check_messages` or `wait_for_message`, or to `redline check` or `redline wait` run in the project folder. The MCP reply gives the report's folder and the text of `report.md`, with snapshots attached up to about 700 KB and the rest named by path.

When Redline starts, it also sends on the reports no chat took while it was stopped: those with a pick from Send to, those it was in the middle of sending, and others that arrived in the last hour.

## Report files

Each report is a folder in `~/Library/Application Support/Redline/inbox/<bundle ID>`, named by the report ID and the end of the device ID, such as `20261004-142233-0E12001C`:

- `report.md`: a summary for the agent, with the app and version, the device and iOS version, each screen's notes, and which snapshot shows each note.
- `report.json`: the same in full, with each element's frame, role, label, value, identifier and class, the named elements that hold it, and where its outline sits in its snapshot.
- The snapshots, each named by a UUID. There is one per screen, with every note on it outlined. A screen you scrolled while noting is stitched into one tall snapshot, cut between rows into parts when it is taller than about two screens.
- The attachments: photos, and whole screens from the capture button, each as its own file.

When a screen's content changed between notes, such as a switched segment, earlier notes move onto the newer snapshot if their elements look the same there. The others keep a snapshot of the earlier state. In the chat's message, a line under such a snapshot's path says what it shows, such as `Editor, earlier state, before the screen changed` or `Editor, part 2 of 2`.

## What the installer checks and runs

- **Before it builds,** it checks for macOS 15 or later, a user other than root, Xcode installed and selected with its license accepted and its first launch done, `devicectl`, Swift 6.2 or later (Xcode 26 or later), git, and 3 GB of free disk space.
- **The source** is a copy of the npm package, or, run with curl, the `main` branch (or `REDLINE_REF`), in `~/Library/Caches/Redline/source`. Run from a checkout, it builds that checkout. git is never allowed to ask for a sign-in.
- **Signing.** `Redline.app` is signed with your Apple Development certificate when one can be used, which it can't over SSH or with the keychain locked. Otherwise it is signed ad hoc.
- **Claude Code** is set up when `~/.claude` exists, the Claude app is installed or the `claude` command is found. With the Claude app, the command must be version 2.1.285 or later. The MCP server is added with `claude mcp add --scope user redline -- ~/.local/bin/redline mcp`. If another tool's server already has the name `redline`, it stays, and the checklist says so.
- **Codex** is set up when `~/.codex` exists or the `codex` command is found.
- **Earlier setups.** It removes Redline hooks an earlier setup left in `~/.claude/settings.json` or `~/.cursor/hooks.json`, backing each file up first as `.before-redline`. It also replaces the earlier version, Agentic Debugging: its app, its `agentic-debugging` command and its MCP entry go, and its data moves into `~/Library/Application Support/Redline`.
- `--no-start` installs without adding the login item or starting Redline, for tests and CI.
- The uninstaller exits with status 1 when it couldn't remove something, or when Redline didn't stop when asked.
