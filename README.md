<p align="center">
  <img src="docs/images/redline-icon.png" width="128" height="128" alt="Redline icon: a phone with one element outlined in red and numbered">
</p>

# Redline

Redline lets you point at UI in a Debug build of your iOS app, on an iPhone or in a simulator, write a note, and send it straight into the Claude Code or Codex chat working on that app. The agent gets a snapshot of each screen with every element you noted outlined in red and numbered, plus each element's name, role and identifier from the accessibility tree, so it can find the view in the code without guessing. It is the way a designer redlines a screen, done on the running app.

It replaces the loop of taking a screenshot, moving it to the Mac, pasting it into a chat and describing which button you mean.

<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="docs/images/redline-hero-dark.svg">
    <source media="(prefers-color-scheme: light)" srcset="docs/images/redline-hero-light.svg">
    <img src="docs/images/redline-hero-light.svg" width="880" alt="An iPhone running a notes app in Redline's annotate mode, with the Save button outlined in red and numbered 1 and the Title field numbered 2. An arrow runs through the Redline menu bar app on the Mac to a Claude Code or Codex chat, which shows the report it received: the snapshot with the same two red outlines (attached in Codex, read from its inbox path in Claude Code), then note 1, Save (Button, editor.save): The button sits under the keyboard on small phones, and note 2, Title (Text field, editor.title): Placeholder is hard to read in dark mode.">
  </picture>
</p>

Status: early development (version 0.1). Supported agents: Claude Code and Codex.

## Contents

- [How it works](#how-it-works)
- [What the agent receives](#what-the-agent-receives)
- [Requirements](#requirements)
- [Install on the Mac](#install-on-the-mac)
- [Add Redline to your iOS app](#add-redline-to-your-ios-app)
- [Send your first report](#send-your-first-report)
- [Using Redline](#using-redline)
- [What ships where](#what-ships-where)
- [Privacy and security](#privacy-and-security)
- [Troubleshooting](#troubleshooting)
- [Command reference](#command-reference)

## How it works

The dashed arrows are setup and happen before the first report. The solid ones carry each report. The numbers match the list below.

<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="docs/images/redline-how-it-works-dark.svg">
    <source media="(prefers-color-scheme: light)" srcset="docs/images/redline-how-it-works-light.svg">
    <img src="docs/images/redline-how-it-works-light.svg" width="880" alt="Two dashed zones, iPhone or simulator on the left and Mac on the right. On the left, your app's Debug build with the Redline kit inside. On the Mac, the Redline hub, a menu bar app with an inbox folder, and a Claude Code or Codex chat in your project. Four numbered arrows: 1, the chat registers its app with the hub; 2, the hub gives the app the Mac's address and a token; 3, the app sends a report to the hub; 4, the hub hands the report and its snapshots to the chat.">
  </picture>
</p>

1. **Registers its app.** A Claude Code or Codex chat open in your app's project tells the hub which apps the project builds: Claude Code through `redline mcp`, when the chat starts, and Codex through the hook `redline setup` installs, the next time you send the chat a message.
2. **Address and token.** The hub leaves `hub.json` in the app's data container: the Mac's addresses, port 47361 and a token for that phone and app.
3. **Report.** You tap the floating button, tap elements, write notes and tap Send. The first time you send from a build, the app asks the hub which open chats work on this app, with the one in this build's worktree first, and you pick one in Send to. The kit saves the report on the device (`report.json`, `report.md` and the snapshots). An iPhone offers it to the hub with the token and uploads the files the hub asks for; from a simulator, the hub copies the finished report out of the app's folder itself.
4. **Report and snapshots.** The hub files the report in its inbox, chooses the chat, and hands it over with the path of each snapshot. A Mac notification says where it went.

### The parts

- **Redline kit** (the `Redline` Swift package). You add one line, `.redline()`, to your app's root view. In Debug builds it shows a floating button, lets you pick elements and write notes, saves each report on the device, and sends it to the Mac.
- **Redline hub** (`Redline.app`, the menu bar app). It gives each watched app on each paired iPhone the Mac's address, takes reports off phones and simulators, files them in an inbox, and hands each one to a chat. Its menu bar panel shows the active devices and the reports sent.
- **The `redline` command.** The same program, run from Terminal. Chats run it to register their app (step 1).

The hub only takes reports for apps that an open chat builds. It finds them by reading the bundle IDs of the iOS app targets in the Xcode projects (or XcodeGen `project.yml`) in each chat's folder.

### How the phone finds the Mac

Steps 2 and 3 travel differently on a physical iPhone and in a simulator:

<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="docs/images/redline-phone-and-simulator-dark.svg">
    <source media="(prefers-color-scheme: light)" srcset="docs/images/redline-phone-and-simulator-light.svg">
    <img src="docs/images/redline-phone-and-simulator-light.svg" width="880" alt="Steps 2 and 3, drawn twice. Physical iPhone: the hub, on the Mac, puts hub.json in the app over Xcode's device link, and the app sends the report to the hub over the local network. Simulator: the app and the hub are both on the Mac; the hub writes hub.json with 127.0.0.1, used only to list chats, and copies the finished report from the app's folder itself.">
  </picture>
</p>

- **iPhone.** An app cannot find the Mac on its own, so the hub leaves the address in the app's folder over Xcode's device link (`devicectl device copy to`). The address lists the Mac's IPv4 addresses on Wi-Fi and Ethernet (not VPN links) and its `.local` name, port 47361, the phone's ID and a token for that phone and app. The hub writes it once, and again only when the Mac's address changes. It looks again for newly paired phones and newly installed apps every 30 minutes, when a chat for a new app opens, and when the Mac's network changes.
- **A phone that can't be reached** (asleep, out of range, on another network) is tried again after 30 seconds, then after waits that double up to 5 minutes. The hub also watches for the announcement a phone makes on the network when it wakes, and tries again right away.
- **Simulator.** A simulator app's files are ordinary files on the Mac, so the hub watches them with file system events. No network or `devicectl` is involved in sending.

### Which chat gets the report

This is step 4 in detail.

```mermaid
flowchart TD
    a["Report filed in the inbox"] --> b{"Was a chat picked in Send to?"}
    b -->|"Yes, an open chat"| c["That chat"]
    b -->|"Yes, New chat"| d{"Did this New chat pick already start a chat?"}
    d -->|"Yes"| e["The chat that pick started"]
    d -->|"No"| f["Make a new worktree from main and start a chat there"]
    b -->|"No pick"| g{"Open chats in the worktree the app was built from"}
    g -->|"Exactly one"| h["That chat"]
    g -->|"None"| f
    g -->|"Several"| i["Waits in the inbox until you pick on the phone"]
```

- **The phone's Send to pick comes first.** The first time you send from a build, the phone asks the Mac for the open chats that work on this app and shows them. The chat working in the worktree the app was built from is selected for you and tagged "This build". Your pick is kept for later reports from builds of the same worktree.
- **Otherwise, the chat in the worktree the app was built from.** `.redline()` records the path of the source file that calls it at compile time. The hub walks up from that path to the folder holding `.git`, and looks for an open chat whose folder is in that same worktree.
- **New chat** makes a new git worktree on a branch named `report/<report ID>`, from the repository's main branch (origin's default branch, fetched first, or else a local `main` or `master`), and starts a chat there. Later reports sent with the same pick go to that chat while its worktree exists. Picking New chat again starts another one. If no chat works in the worktree and nothing was picked, the hub also starts a new chat, with the first agent installed.
- **New chats start read-only.** The hub starts them with the agent's command line, Claude Code in plan mode and Codex in a read-only sandbox, then opens the chat in the Claude app or the Codex app, or in Terminal when that app is not installed.

### How the chat receives it

- **Claude Code.** The report goes in through the chat's own message socket and starts a turn, even when the chat is idle. If the chat has closed, the hub resumes it with `claude --resume`, in the Claude app when it is installed or else in Terminal, then sends the report.
- **Codex.** The report starts a turn through the Codex app, with its snapshots attached the way the app attaches a screenshot you add. If no Codex window has the chat open, the hub opens it first. If the app can't take it, the report goes in with your next message in that chat, through the hook `redline setup` adds. The Codex app's socket is the app's own, not a published interface, so a Codex update can change it; the hook is the fallback.

## What the agent receives

The snapshot at the top shows the first screen of this report. Each snapshot is named by its full path, followed by the notes on it. The numbers match the red outlines in the snapshot. Each note names the element by its accessibility label (or identifier), then its role and identifier:

```text
UI report from Alex's iPhone · Sample Notes

/Users/alex/Library/Application Support/Redline/inbox/com.example.notes/20261004-142233-0E12001C/5E0C2A4B-7F1D-4C39-9A0E-2B6D8F41C3A7.jpg
1. Save (Button, editor.save): The button sits under the keyboard on small phones
2. Title (Text field, editor.title): Placeholder is hard to read in dark mode

/Users/alex/Library/Application Support/Redline/inbox/com.example.notes/20261004-142233-0E12001C/C81D3F07-52B6-4E8A-B19C-6A04D7E2F915.jpg
3. Photo: This is how it looked in the last build
```

Snapshot file names say nothing about what they show, so when a snapshot is an earlier state of a screen, or one part of a tall one, a line under its path says so, such as `Editor, earlier state, before the screen changed` or `Editor, part 2 of 2`.

The report folder also holds:

- `report.md`: a summary for the agent: the app and version, the device and iOS version, each screen's notes, and which snapshot shows each note.
- `report.json`: the same in full: each element's frame, role, label, value, identifier and class, the bigger elements that hold it, and where its outline sits in its snapshot.
- The snapshots, each named by a UUID, such as `5E0C2A4B-7F1D-4C39-9A0E-2B6D8F41C3A7.jpg`: one per screen with every note on it outlined. A screen you scrolled while noting is stitched into one tall snapshot, and one taller than about two screens is cut between rows into parts. A screen whose content changed between notes, such as a switched segment, gets a snapshot of each state, and each note is outlined on the state it was made on. Attachments are snapshots too. `report.md` and `report.json` say what each file shows.

A chat that calls the MCP tool `check_messages` gets `report.md` with the snapshots attached instead.

## Requirements

- A Mac with macOS 15 or later.
- Xcode 16 or later (the package uses Swift tools 6.0, and the hub uses Xcode's `devicectl`). Redline has been built and tested with Xcode 27 only. Select Xcode with `xcode-select` if you have more than one.
- Your app targets iOS 18 or later and uses SwiftUI.
- Claude Code, Codex, or both on the Mac. For Claude Code, the `claude` command must be installed and signed in: the hub uses it to start new chats.
- For a physical iPhone: the phone is paired with the Mac in Xcode (you can run builds on it), and the phone and Mac are on the same local network.

## Install on the Mac

There are three ways in, and all three run the same installer, [`install.sh`](install.sh). It builds Redline from source with your Xcode, so the first run takes a few minutes.

1. **Ask your agent.** In a Claude Code or Codex chat open in your app's project, paste:

   ```text
   Install Redline from https://github.com/mericksters13/agent-redline-ios and add it to this app.
   ```

   The agent follows [INSTALL.md](INSTALL.md): it runs the installer, adds the package and `.redline()` to your app, builds it, and tells you what is left for you to do.

2. **npx** (needs Node.js 18 or later):

   ```sh
   npx agent-redline-ios
   ```

   If npm can't find the package yet, run it from GitHub: `npx github:mericksters13/agent-redline-ios`.

3. **curl:**

   ```sh
   curl -fsSL https://raw.githubusercontent.com/mericksters13/agent-redline-ios/main/install.sh -o "${TMPDIR:-/tmp}/redline-install.sh" && bash "${TMPDIR:-/tmp}/redline-install.sh"
   ```

   It saves the script first and runs it only when the download worked, so a failed download ends with an error instead of an empty run that exits 0. The script then downloads the `main` branch. To install a particular branch, tag or commit, set `REDLINE_REF`: `REDLINE_REF=<commit> bash "${TMPDIR:-/tmp}/redline-install.sh"`.

The installer asks for nothing it can do without: with `--no-input` (for example `npx agent-redline-ios --no-input`), or when a coding agent or CI runs it, it never waits for an answer and lists what is left for you.

### What the installer does

Each step is safe to run again: nothing is added twice, and a run that stopped partway can be run again.

1. **Checks the Mac:** macOS 15 or later, not run as root, Xcode installed and selected with its license accepted and its first launch done, `devicectl`, Swift 6 or later, git, and 3 GB of free disk space. When something is missing it stops with the one command to fix it, such as `sudo xcodebuild -license accept`; run that, then run the same install command again. The installer never runs `sudo` itself.
2. **Gets the source:** the checkout it runs from, or a copy of the npm package in `~/Library/Caches/Redline/source`, so the build lands in a folder you own and later versions reuse it. Run with curl, it downloads the `main` branch into that same folder and updates that copy on later runs. git is never allowed to ask for a sign-in: a repository or branch it can't reach stops the installer with the fix.
3. **Builds the `redline` command** with `swift build -c release --product redline`. The build log is `~/Library/Application Support/Redline/install.log`; if the build fails, the installer shows the last errors and stops.
4. **Installs the command** as `~/.local/bin/redline`, copied from the build output. If `~/.local/bin` is not on your `PATH` and your shell is zsh, it adds one line to `~/.zprofile`; for another shell, it gives you the line to add.
5. **Builds and installs `Redline.app`** in `~/Applications` with `scripts/build-hub-app.sh`. Keep it there: chats look for the app there to start it. The app is signed with your Mac's Apple Development certificate when you have one and it can be used (it can't over SSH or with the keychain locked), and ad hoc otherwise. A running copy is stopped and opened again (with `--no-start`, it is stopped and not opened again).
6. **Runs `redline setup`:**
   - **Claude Code**, when `~/.claude` exists or the Claude app is installed. Setup checks that the `claude` command is installed, signed in, and, with the Claude app, version 2.1.285 or later. The `claude` command starts new chats for reports and has its own sign-in, separate from the Claude app's. In a terminal, setup runs `claude update` and `claude auth login` for you. With no terminal to ask in, with `--no-input`, or when an agent runs the installer, it runs neither and lists them for you instead. Either way it goes on with the rest.
   - **Codex**, when `~/.codex` exists. Setup adds one hook, on `UserPromptSubmit`, named "Report delivery", to `~/.codex/hooks.json`. Your other hooks stay as they are, and the file is backed up once as `hooks.json.before-redline`.
   - Claude Code needs no hooks, so setup leaves `~/.claude/settings.json` as it is.
   - Cursor gets no hooks. Hooks an earlier setup added to `~/.cursor/hooks.json` are removed.
   - **The earlier version**, Agentic Debugging, is replaced: its app in `~/Applications` is stopped and removed, its command `~/.local/bin/agentic-debugging` is removed once setup has moved its hooks to `redline`, and its data folder, `~/Library/Application Support/iOSAgenticDebuggingKit`, moves to `~/Library/Application Support/Redline`, so reports and paired phones carry over. The data moves only after the new command and app are installed, so a run that stops earlier leaves the earlier version working with its data; that run's log and checklist are in `~/Library/Caches/Redline`.
7. **Adds the MCP server to Claude Code**, once, when the `claude` command is installed: `claude mcp add --scope user redline -- ~/.local/bin/redline mcp`. Each Claude Code chat then runs `redline mcp`, which registers the chat and the apps its project builds with the hub, and opens Redline when it is not running. In projects that build no iOS app it does nothing. It also gives the chat two tools, `check_messages` and `wait_for_message`, for taking reports that are waiting in the inbox. An entry left from Redline's earlier name, `agentic-debugging`, is removed. Another tool's MCP server already named `redline` stays: the checklist lists it under Needs you instead of replacing it.
8. **Opens Redline at login and starts it:** a login item, `~/Library/LaunchAgents/com.agentredline.hub.plist`, opens Redline in the background at login. A Redline icon appears in the menu bar. `--no-start` skips this step, for tests and CI.
9. **Ends with a checklist** of each step, marked Done, Needs you or Skipped, with the exact command or click for each Needs you. It is saved in `~/Library/Application Support/Redline/install-report.txt`.

### What may need you afterwards

The checklist lists what only you can do. Depending on your Mac, that is:

- **Sign in the `claude` command:** `claude auth login`, or `claude update` when it is too old for the Claude app. Setup does this for you when it has a terminal to ask in.
- **Trust the Codex hook:** Codex runs a new hook only after you trust it. In Codex, open `/hooks` and trust "Report delivery".
- **Open a new terminal** when the installer added `~/.local/bin` to your `PATH`.
- **Start a new Claude Code chat** in your project, or restart the open one: a chat loads its MCP servers when it starts.

The first time Redline runs, macOS asks once whether it may show notifications, and may say a background item was added: that is the login item.

### Update

Update the Mac first, then rebuild your apps against the new package. A newer hub reads reports from older apps, but an older hub may not fully read a report whose format changed: it still delivers it, without the notes in its panel and with the snapshots out of order.

To update the Mac, run the install command again. It rebuilds the command and the app, replaces them, and restarts Redline. With npx, ask for the latest version, or npx may reuse the copy it downloaded before:

```sh
npx agent-redline-ios@latest
```

Run with curl, the installer downloads the latest `main`. From a checkout, it builds the checkout as it is, so `git pull` first.

### Uninstall

```sh
npx agent-redline-ios uninstall
```

or

```sh
curl -fsSL https://raw.githubusercontent.com/mericksters13/agent-redline-ios/main/install.sh -o "${TMPDIR:-/tmp}/redline-install.sh" && bash "${TMPDIR:-/tmp}/redline-install.sh" uninstall
```

It removes Redline's hooks (with `redline remove`, or by itself when the command is already gone; other hooks stay), the MCP entry in Claude Code (not another tool's server named `redline`), the login item, `Redline.app`, `~/.local/bin/redline`, the line it added to `~/.zprofile`, and its download cache. Reports stay in `~/Library/Application Support/Redline` until you delete that folder, and so do the `.before-redline` backups of your settings. If the app, the command, the login item, a hook or the MCP entry can't be removed, or Redline doesn't stop when asked, the checklist says so under Needs you and the uninstaller exits with status 1. In your app, remove the `.redline()` line and the package.

### From source

To work on Redline itself, clone the repository and run the installer from the checkout. It builds and installs that checkout instead of downloading one:

```sh
git clone https://github.com/mericksters13/agent-redline-ios.git
cd agent-redline-ios
bash install.sh
```

Run it again after each change. `swift test` runs the tests. To rebuild only the app, run `scripts/build-hub-app.sh`. Install the `redline` command from `swift build -c release --product redline`, as the installer does; do not copy the executable out of `Redline.app`, because macOS stops a copy taken out of the signed app bundle.

## Add Redline to your iOS app

An agent asked to add Redline to your app does these steps for you, following [INSTALL.md](INSTALL.md).

1. **Add the package.** In Xcode, choose File > Add Package Dependencies and enter:

   ```text
   https://github.com/mericksters13/agent-redline-ios.git
   ```

   There are no version tags yet, so choose the `main` branch.

2. **Add the `Redline` library to your app target** when Xcode asks which product to add. In a `Package.swift`, the dependency is:

   ```swift
   .package(url: "https://github.com/mericksters13/agent-redline-ios.git", branch: "main")
   // in the app target's dependencies:
   .product(name: "Redline", package: "agent-redline-ios")
   ```

   In an XcodeGen `project.yml`:

   ```yaml
   packages:
     Redline:
       url: https://github.com/mericksters13/agent-redline-ios.git
       branch: main
   targets:
     YourApp:
       dependencies:
         - package: Redline
           product: Redline
   ```

3. **Add one line to your root view.**

   ```swift
   import SwiftUI
   import Redline

   @main
   struct SampleApp: App {
       var body: some Scene {
           WindowGroup {
               ContentView()
                   .redline()
           }
       }
   }
   ```

That is all: no Info.plist keys, permissions, build settings or build phases. You don't need `#if DEBUG` around the call; in Release builds, `.redline()` returns the view unchanged.

On a physical iPhone, iOS asks once whether the app may find devices on the local network, the first time it talks to the Mac. Allow it, or reports can't reach the Mac.

## Send your first report

1. Make sure Redline is running on the Mac (its icon is in the menu bar).
2. Open a Claude Code or Codex chat in the app's project. A Claude Code chat registers when it starts; a Codex chat registers the next time you send it a message.
3. Build and run the Debug build from Xcode, on a paired iPhone or a simulator. The menu bar panel then shows the device as Ready (a phone) or Running (a simulator).
4. In the app, tap the floating Redline button, tap an element, write a note and tap Add note.
5. Tap Send. The first time, pick the chat in Send to and confirm.
6. The report appears in the chat, and the menu bar panel lists it with the chat it went to.

## Using Redline

### On the phone

- **The floating button.** Tap it to start marking up the screen. Drag it anywhere; it snaps to the nearest screen edge. Press and hold it to see the reports sent from this device.
- **Annotate mode.** A light red line runs around the screen while Redline has it, and the controls sit in a black bar at the top. Tap any element to select it; Smaller and Larger step to a part of it or to the bigger element around it. Write a note and tap Add note. Keep going across screens: notes collect until you send them. Tap the close button in the bar to use the app again; the notes stay.
- **Notes tray.** Tap the screen name in the bar to see the waiting notes. Tap one to see its snapshot and note full screen, or delete it. The draft is saved on the device, so it survives the app being killed or reinstalled by a rebuild.
- **Screenshots and attachments.**
  - Take a screenshot as usual. A thumbnail appears beside the floating button; tap it to write a note and send. Redline captures the app's own windows at that moment, so Redline itself is never in the snapshot.
  - In annotate mode, the capture button attaches the whole screen as it is, and the paperclip attaches photos.
  - Apps that already declare Photos access in their Info.plist show a grid of recent photos, and ask for access only when you tap Show recent photos. With that access, Redline also offers screenshots taken in other apps when you come back to yours. Other apps get the system photo picker, which needs no access.
  - Notes on elements and attachments go together in one report.
- **Send to.** The row in the notes tray shows where reports go, and changes it. The picker has one tab per agent on the Mac, a New chat row ("In a new worktree from main"), and the open chats that work on this app, the one in this build's worktree first.
- **Delivery.** After Send, a short message says whether the report reached the Mac. A report that didn't is kept on the device. Once one report has reached the Mac, the app offers any it hasn't confirmed again each time the app comes back to the foreground. The sent reports list shows "On the Mac" for each report, or why it isn't there yet.

### On the Mac

Click the Redline icon in the menu bar to open the panel:

- **Header:** the address and port apps reach the Mac at.
- **Devices:** paired iPhones that are ready and running simulators with a watched app, with the time of each one's last report. Paired phones that can't take reports right now are dimmed, with the reason, such as Not reachable or No watched app installed.
- **Reports:** the 30 newest, each with its first snapshot, the device, when it arrived, the agent and chat it went to (or why it is waiting), and its first notes. Click a report to open it in a viewer window: its snapshots with the numbered outlines, and its notes beside them; click a note to bring its snapshot into view. **Open in Claude Code** or **Open in Codex** reopens the chat the report went to, and **Show in Finder** shows the report's folder.
- **Open inbox** opens the inbox folder in Finder. **Quit** stops the hub.

Each report also posts a Mac notification saying where it went.

## What ships where

- **Debug builds only.** Every kit source file except the public modifier is compiled only when the `REDLINE` flag is set, and `Package.swift` sets it only for the Debug configuration. Release builds, including TestFlight and App Store builds, get an empty module, and `.redline()` returns the view unchanged.
- **Private API, Debug only.** SwiftUI builds its accessibility tree only when an assistive client is connected. To read element names and roles, the kit turns on the automation mode UI tests use, through the private `AXSSetAutomationEnabled` function, loaded at run time. That code is inside the `REDLINE` flag, so it is not in Release builds.
- **The Mac side never ships in your app.** `redline` and `Redline.app` are Mac-only targets in the same package. Your app links only the `Redline` library.

## Privacy and security

- **Local network only.** Redline has no server and no account. Reports go from the phone to your Mac over your local network (TCP port 47361), or from a simulator's folder on the same Mac. The connection is plain TCP, not encrypted; what guards it is the token below. The hub's one use of the internet is `git fetch` of the main branch when it makes a worktree for a new chat.
- **A token per phone and app.** The hub makes a random token for each app on each phone and leaves it, with the address, in the app's folder over Xcode's device link, which only a Mac paired with that phone can do. The hub turns down reports and chat questions that don't carry the right token. Tokens are stored in `~/Library/Application Support/Redline/hub/tokens.json`, readable only by you.
- **Where reports are kept.** On the device: `Library/Application Support/Redline` in the app's own container. On the Mac: `~/Library/Application Support/Redline/inbox`. Nothing is deleted automatically.
- **What the agent sees.** Once a report is in a chat, it is part of that chat like anything you paste in. The snapshots show whatever was on screen, so avoid noting screens with personal data you don't want in a chat.

## Troubleshooting

**The phone says "Saved on this iPhone. Couldn't reach the Mac", or the panel shows the phone as Not reachable.**
The phone is asleep, out of range, or on another Wi-Fi network than the Mac. Wake the phone and put both on the same network. The hub keeps trying (after 30 seconds, then up to every 5 minutes) and tries again as soon as a phone wakes. The report stays on the phone. Once a report from this app has reached the Mac before, the app offers the waiting ones again each time it comes to the foreground; otherwise they go with the next Send. `redline status` shows each phone's state and the addresses apps use.

**The phone says "Not on the Mac yet: no Mac has set up this app".**
The hub has not left its address in the app yet. Check that Redline is running, that a chat for the app's project is open (see [Send your first report](#send-your-first-report)), and that Xcode can reach the phone. The panel shows "No watched app installed" when the installed app's bundle ID isn't one the hub found in a chat's project.

**macOS asks whether Redline may access files in your Documents folder.**
Redline reads the project folders of your open chats to learn which app each one builds, and those folders are often in Documents. Allow it. macOS asks once, because the app is signed with your Mac's Apple Development certificate and keeps the same identity across rebuilds. Without that certificate the script signs ad hoc, and macOS may ask again after every rebuild.

**Reports never reach a Codex chat, or wait for the next message.**
Open `/hooks` in Codex and trust "Report delivery". If you installed Codex after running setup, run `~/.local/bin/redline setup` again. A Codex chat registers with the hub only when you send it a message.

**A notification says to run `claude auth login`.**
The `claude` command, which starts new Claude Code chats, is not signed in, or is too old for the Claude app. The report waits in the inbox. Run `claude auth login`, or `~/.local/bin/redline setup`, which checks both.

**A report waits in the inbox.**
The panel says why, for example when several chats work in the same worktree and none was picked. Pick a chat in Send to on the phone for the next report. To take the waiting ones, call `check_messages` in a Claude Code chat with the MCP server, or run `redline check` in the project folder.

**"Couldn't find devicectl."**
Install Xcode and select it: `sudo xcode-select -s /Applications/Xcode.app`.

The hub's log is at `~/Library/Application Support/Redline/hub/hub.log`.

## Command reference

| Command | What it does |
|---|---|
| `redline setup` | Checks the `claude` command, adds the Codex hook and removes Cursor hooks from an earlier setup. With `--no-input`, or with no terminal, it lists what you need to run instead of running `claude update` or `claude auth login`. |
| `redline remove` | Removes Redline's hooks. Other hooks stay. |
| `redline status` | Shows what the hub is doing, each phone's state and what's in the inbox. |
| `redline check` | Prints the reports waiting for the current project's apps and takes them. |
| `redline wait` | Waits for the next report for the current project's apps, then prints it. |
| `redline mcp` | The MCP server a Claude Code chat runs. |
| `redline hub` | The hub without the menu bar app. |
| `redline app` | The menu bar app; opening `Redline.app` does the same. |

`check`, `wait` and `mcp` take `--project <folder>`, and `--app <bundle ID>` for a bundle ID that can't be read from the project.

## Contributing

To build, test and send a change, see [CONTRIBUTING.md](CONTRIBUTING.md). How the code is written is in [docs/CODE_STYLE.md](docs/CODE_STYLE.md).

## Acknowledgements

The kit's walk of the accessibility tree and its automation switch follow the approach of [AnnotateKit](https://github.com/Connected-Mate/AnnotateKit) (MIT).
