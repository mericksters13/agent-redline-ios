<p align="center">
  <img src="docs/images/redline-icon.png" width="128" height="128" alt="Redline icon: a phone with one element outlined in red and numbered">
</p>

# Redline

Redline lets you point at UI in a Debug build of your iOS app, on an iPhone or in a simulator, write a note, and send it to the Claude Code or Codex chat working on that app. It is how a designer redlines a screen, done on the running app.

The agent gets a snapshot of each screen with the elements you noted outlined in red and numbered, plus each element's accessibility label, role and identifier, so it can find the view in your code. Redline replaces taking a screenshot, moving it to the Mac, pasting it into a chat and describing which button you mean.

<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="docs/images/redline-hero-dark.svg">
    <source media="(prefers-color-scheme: light)" srcset="docs/images/redline-hero-light.svg">
    <img src="docs/images/redline-hero-light.svg" width="880" alt="An iPhone in Redline's annotate mode, with the Save button outlined in red and numbered 1 and the Title field numbered 2. An arrow runs through the Redline menu bar app on the Mac to a Claude Code or Codex chat, which shows the report: the snapshot with the same two outlines, then note 1, Save (Button, editor.save): The button sits under the keyboard on small phones, and note 2, Title (Text field, editor.title): Placeholder is hard to read in dark mode.">
  </picture>
</p>

Version 0.1.0, early development. Works with Claude Code and Codex only. The Agents section in the menu bar panel, the Built from line in Send to and the SwiftUI hint described below are on `main` and not yet in a release.

## How it works

Redline has two parts:

- **The kit**, the `Redline` Swift package. It goes into your app with one line, `.redline()`, and runs only in Debug builds.
- **The Mac side**: `Redline.app`, a menu bar app (the hub in the figures), and the `redline` command that chats and Terminal use.

<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="docs/images/redline-how-it-works-dark.svg">
    <source media="(prefers-color-scheme: light)" srcset="docs/images/redline-how-it-works-light.svg">
    <img src="docs/images/redline-how-it-works-light.svg" width="880" alt="Two dashed zones, iPhone or simulator on the left and Mac on the right. On the left, your app's Debug build with the Redline kit inside. On the Mac, the Redline hub, a menu bar app with an inbox folder, and a Claude Code or Codex chat in your project. Four numbered arrows: 1, the chat registers its app with the hub; 2, the hub gives the app the Mac's address and a token; 3, the app sends a report to the hub; 4, the hub hands the report and its snapshots to the chat.">
  </picture>
</p>

1. **A chat registers its app.** Redline reads the app's bundle ID from the Xcode project (or XcodeGen `project.yml`) in the chat's folder. It takes reports only for apps a chat works on now or has worked on before.
2. **Redline sets up the app.** It writes the Mac's address and a token into a file, `hub.json`, in the app's data container. On an iPhone it does this over Xcode's device link, because the app can't find the Mac on its own.
3. **You send a report.** Tap the floating button, tap elements, write notes and tap Send. From an iPhone, the app saves the report and sends it over the local network. In a simulator, Redline copies it out of the app's folder.
4. **Redline hands it to a chat.** It files the report in its inbox and gives it to a chat, with the path of each snapshot.

Steps 2 and 3 on an iPhone and in a simulator:

<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="docs/images/redline-phone-and-simulator-dark.svg">
    <source media="(prefers-color-scheme: light)" srcset="docs/images/redline-phone-and-simulator-light.svg">
    <img src="docs/images/redline-phone-and-simulator-light.svg" width="880" alt="Steps 2 and 3, drawn twice. Physical iPhone: the hub, on the Mac, puts hub.json in the app over Xcode's device link, and the app sends the report to the hub over the local network. Simulator: the app and the hub are both on the Mac; the hub writes hub.json with 127.0.0.1, used only to list chats, and copies the finished report from the app's folder itself.">
  </picture>
</p>

[How Redline works](docs/HOW-IT-WORKS.md) has the details: when Redline looks for phones and apps, how a chat is chosen and reached, and what each report file holds.

## What the agent receives

A report arrives in the chat as a message like this one. Notes 1 and 2 are the ones in the figure at the top. Note 3 is an attached photo.

```text
UI report from Alex's iPhone · Sample Notes

/Users/alex/Library/Application Support/Redline/inbox/com.example.notes/20261004-142233-0E12001C/5E0C2A4B-7F1D-4C39-9A0E-2B6D8F41C3A7.jpg
1. Save (Button, editor.save): The button sits under the keyboard on small phones
2. Title (Text field, editor.title): Placeholder is hard to read in dark mode

/Users/alex/Library/Application Support/Redline/inbox/com.example.notes/20261004-142233-0E12001C/C81D3F07-52B6-4E8A-B19C-6A04D7E2F915.jpg
3. Photo: This is how it looked in the last build
```

Each snapshot's path comes first, then its notes, numbered like its outlines. A note reads `Label (Role, identifier): note`. Without a label, the identifier is the name. When the element sits inside other named elements, they follow, such as `in Cell "Milestones" (today.list)`, so the agent can tell apart elements that share a label.

When the Codex app takes a report, the snapshots come attached. Claude Code opens them from their paths. Each report's folder also holds `report.md` (a summary) and `report.json` (everything the kit read about each element, such as its frame, value and class).

## Requirements

- A Mac with macOS 15 or later.
- Xcode 16 or later (so far tested only with Xcode 27).
- A SwiftUI app that targets iOS 18 or later.
- An Xcode project or XcodeGen `project.yml` in the folder your chat works in. Redline reads the app's bundle ID from it.
- Claude Code, Codex, or both. Claude Code also needs the `claude` command installed and signed in (see [After installing](#after-installing)).
- For an iPhone: the phone is paired with the Mac in Xcode, and both are on the same local network.

## Install on the Mac

All three ways run the same installer, [`install.sh`](install.sh). It builds Redline from source with your Xcode, so the first run takes a few minutes.

1. **Ask your agent.** In a Claude Code or Codex chat open in your app's project, paste:

   ```text
   Install Redline from https://github.com/mericksters13/agent-redline-ios and add it to this app.
   ```

   The agent follows [INSTALL.md](INSTALL.md): it runs the installer, adds the package and `.redline()` to your app, builds it, and tells you what is left for you to do.

2. **npx** installs the latest release. It needs Node.js 18 or later.

   ```sh
   npx agent-redline-ios
   ```

3. **curl** builds the newest code on `main`.

   ```sh
   (f="$(mktemp)" && trap 'rm -f "$f"' EXIT && curl -fsSL https://raw.githubusercontent.com/mericksters13/agent-redline-ios/main/install.sh -o "$f" && bash "$f")
   ```

   To build another branch, tag or commit, put `REDLINE_REF=<ref>` before `bash`.

When a coding agent or CI runs the installer, or you add `--no-input`, it never waits for an answer. It lists what is left for you instead.

### What the installer changes

It is safe to run again, and it never runs `sudo`. If something needs you first, such as accepting the Xcode license, it stops and shows the command that does it. Run that, then run the installer again.

- Installs the `redline` command in `~/.local/bin`. If that folder isn't on your `PATH`, it adds a line to `~/.zprofile` for zsh. For another shell, the checklist says how to add it.
- Installs `Redline.app` in `~/Applications`, with a login item that starts it from there (`~/Library/LaunchAgents/com.agentredline.hub.plist`). Don't move the app.
- For Claude Code, it checks that the `claude` command is signed in and new enough, and adds Redline's MCP server for all your projects (`claude mcp add --scope user`). In a terminal, it runs `claude update` and `claude auth login` for you when needed.
- For Codex, it adds one hook, "Report delivery", to `~/.codex/hooks.json`. Your other hooks stay, and the file is backed up first as `hooks.json.before-redline`.
- Keeps its source and build cache in `~/Library/Caches/Redline`, and its log, reports and settings in `~/Library/Application Support/Redline`.

In a project that builds no iOS app, the MCP server and the hook do nothing.

It ends with a checklist marked Done, Needs you or Skipped, also saved in `~/Library/Application Support/Redline/install-report.txt`.

### After installing

The checklist lists what only you can do, with the command for each. The usual ones:

- **Sign in the `claude` command** with `claude auth login`, or run `claude update` if it is too old for the Claude app. Redline uses it to start new Claude Code chats and reopen closed ones. It has its own sign-in, separate from the Claude app's.
- **Trust the Codex hook.** In Codex, open `/hooks` and trust "Report delivery". Codex runs a new hook only after you trust it, and a Codex chat registers its app through this hook.
- **Open a new terminal** if the installer added `~/.local/bin` to your `PATH`.

The first time Redline runs, macOS asks whether it may show notifications. If your projects are in your Documents folder, macOS also asks whether Redline may access it. Allow it: Redline reads your chats' project folders to learn which app each one builds. macOS may also say a background item was added. That is Redline's login item.

## Add Redline to your iOS app

If your agent installed Redline from the prompt above, it has done this already.

1. **Add the package.** In Xcode, choose File > Add Package Dependencies and enter `https://github.com/mericksters13/agent-redline-ios.git`. Choose Up to Next Major Version from `0.1.0`, and add the `Redline` library to your app target.

   In a `Package.swift`, the dependency is:

   ```swift
   .package(url: "https://github.com/mericksters13/agent-redline-ios.git", from: "0.1.0")
   // in the app target's dependencies:
   .product(name: "Redline", package: "agent-redline-ios")
   ```

   For XcodeGen and Tuist, see [INSTALL.md](INSTALL.md#3-add-the-package-to-the-app-target).

2. **Add one line to your root view.**

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

That is all: no Info.plist keys, build settings or build phases. You don't need `#if DEBUG` around the call: in Release builds it returns the view unchanged (see [What ships in your app](#what-ships-in-your-app)).

The first time you send a report from an iPhone, iOS asks once whether the app may find devices on your local network. Allow it, or reports can't reach the Mac. To explain the prompt in your own words, you can add `NSLocalNetworkUsageDescription` to Info.plist.

## Send your first report

1. Make sure Redline is running on the Mac. Its icon is in the menu bar.
2. Open a Claude Code or Codex chat in the app's project. Redline finds open Claude Code chats on its own. A Codex chat registers the next time you send it a message, once you have trusted its hook.
3. Build and run the Debug build from Xcode, on a paired iPhone or a simulator. The menu bar panel then shows the device as Ready (a phone) or Running (a simulator). Redline looks for newly installed apps every 30 minutes, so if the app is new on that device, click Quit in the panel and open `Redline.app` again to make it look now.
4. In the app, tap the floating Redline button, tap an element, write a note and tap Add note.
5. Tap Send. The first time, pick the chat in Send to and confirm.
6. The report appears in the chat, and the menu bar panel lists it with the chat it went to.

## Using Redline

### On the phone

- **The floating button.** Tap it to start marking up the screen. Drag it anywhere; it snaps to the nearest edge. Press and hold it to see the reports sent from this device.
- **Annotate mode.** A light red line around the screen means your taps go to Redline, not the app. The controls sit in a black bar at the top.
  - Tap an element to select it. Smaller selects a part of it, and Larger selects the element around it.
  - Write a note and tap Add note. Notes collect across screens until you send them.
  - To use the app again, tap the close button in the bar. Your notes stay.
- **Notes tray.** Tap the screen name in the bar to see the notes waiting to be sent. Tap a note to see it full screen with its snapshot, or tap its trash button to delete it. Waiting notes are saved on the device, so they survive the app being killed or reinstalled by a rebuild.
- **Screenshots and photos.**
  - Take a screenshot as usual. A thumbnail appears beside the floating button; tap it to write a note and send. Redline captures the app's own windows at that moment, so Redline itself is never in the snapshot.
  - In annotate mode, the capture button attaches the whole screen as it is, and the paperclip opens a photo panel. Without Photos access, the panel offers the system photo picker, which needs no permission.
  - If your app already declares Photos access in Info.plist, the panel can show your recent photos: tap Show recent photos to allow access. With access, Redline also offers screenshots you took in other apps when you come back to yours.
  - Notes on elements and attachments go together in one report.
- **Send to.** The Send to row in the notes tray shows where reports go. Tap it to choose an agent, then one of its chats that work on this app, or New chat. The picker lists open Claude Code chats and Codex chats used in the last 14 days. Among them, the chat in the git worktree this build came from (your checkout, if you don't use worktrees) comes first, tagged "This build", and is selected. The first Send from a worktree asks you to pick, and later builds from it keep the pick. [Where reports go](#where-reports-go) explains each choice.
- **Delivery.** After Send, a short message says whether the report reached the Mac. A report that didn't stays on the device. The app sends it again when it launches, each time it comes back to the foreground, and with the next Send. The sent reports list shows "On the Mac" for each report, or why it isn't there yet.

### On the Mac

Click the Redline icon in the menu bar to open the panel:

- **Devices:** paired iPhones, and running simulators that have one of your apps, with each one's last report. A phone that can't take reports right now is dimmed, with the reason, such as Not reachable or No watched app installed.
- **Agents:** Claude Code and Codex, whichever are installed, and whether reports can reach their chats right now. When they can't, the row says what happens to reports meanwhile and what to do: for Claude Code, a command, with a button that copies it; for Codex, open or reopen the app.
- **Reports:** the 30 newest, each with its first snapshot, the device, when it arrived, the chat it went to (or why it is waiting) and its first notes. Click one to see its snapshots and notes side by side. **Open in Claude Code** or **Open in Codex** reopens that chat, and **Show in Finder** shows the report's folder.
- At the bottom, **Open inbox** opens the inbox folder, and **Quit** stops Redline.

Each report also posts a Mac notification that says where it went.

## Where reports go

When a report reaches the Mac, it goes to the chat you picked in Send to. With no pick, Redline looks at the git worktree the app was built from, which `.redline()` records at build time:

- **One chat works there:** the report goes to it.
- **No chat works there:** Redline starts a new chat.
- **Several chats work there, or the worktree isn't on this Mac**, such as for a build made on another Mac: the report waits in the inbox until a chat takes it (see [Troubleshooting](#troubleshooting)).

**New chats.** Redline makes a git worktree from your repository's main branch, on a branch named `report/<report ID>`, and starts the chat there. A new Codex chat first looks into the report in a read-only sandbox, then opens in the Codex app. A new Claude Code chat starts in plan mode, then opens in the Claude app, where it gets the report. Without the agent's app, the chat opens in Terminal. Redline sets no permission mode when it opens a Claude Code chat, so the chat may not stay in plan mode.

- A new chat starts from main, not from your build's branch. When the build's worktree isn't on main, the picker says so under New chat, such as "Built from feature/growth-card. A new chat starts from main." If the bug is only on that branch, pick that branch's chat instead.
- With no pick, the new chat uses the agent you last used for this app, or else the first agent that can start one. When you pick New chat, you choose the agent, and later reports with that pick go to the same chat. Picking New chat again starts another.
- A new chat needs its agent's command, `claude` or `codex`, and a main branch to start from. When no chat can start, the report waits in the inbox.

**How each agent takes a report.**

- **Claude Code.** The report starts a turn in the chat, even when the chat is idle. If the chat has closed, Redline first reopens it with `claude --resume`, in the Claude app or in Terminal.
- **Codex.** The report starts a turn through the Codex app. If no window shows the chat, Redline opens it first. If the Codex app isn't running or doesn't answer, the report goes in with your next message in that chat, through the "Report delivery" hook. Redline reaches the Codex app through an interface Codex doesn't publish, so a Codex update can break this until you update Redline. The hook keeps working meanwhile.

## What ships in your app

- **Debug builds only.** `Package.swift` sets the kit's compile flag for the Debug configuration only. Release builds, including TestFlight and App Store builds, get an empty module. `.redline()` returns the view unchanged, and your source file path isn't kept in the binary.
- **A private API, in Debug only.** SwiftUI builds its accessibility tree only for assistive tools. To read element names and roles, the kit turns on the automation mode UI tests use, through the private function `AXSSetAutomationEnabled`, looked up at run time. Release builds don't contain it.
- **No Mac code.** The `redline` executable, which `Redline.app` wraps, is a separate product in the same package. Your app links only the `Redline` library.

## Privacy and security

- **Local network only.** Redline has no cloud service and no account. Reports go from the phone to your Mac over your local network, on TCP port 47361, or from a simulator's folder on the same Mac. For Send to, the Mac sends the phone the chats that work on the app (their titles, folder names and when each was last active) and the branch of the build's worktree.
- **Plain TCP, with a token per phone and app.** The connection isn't encrypted, so others on your local network could read a report as it crosses. Redline makes a random token for each app on each phone and writes it into the app over Xcode's device link, which only a Mac paired with that phone can use. Both sides prove they hold the token without sending it, so the phone sends reports only to the Mac that set it up, and Redline turns away anything else. Tokens are kept in `~/Library/Application Support/Redline/hub/tokens.json`, readable only by you.
- **Internet use.** Redline itself goes online only when it makes a worktree for a new chat: it asks your repository's origin for its main branch and fetches it. The agents it starts work as they always do.
- **Where reports are kept.** On the device, in the app's own container, under `Library/Application Support/Redline`. The app keeps every report the Mac hasn't confirmed, and the 20 newest it has. On the Mac, in `~/Library/Application Support/Redline/inbox`, never deleted automatically. A new Claude Code chat also gets a copy of its report in its worktree's `.redline` folder, which git ignores.
- **What the agent sees.** Once a report is in a chat, it is part of that chat like anything you paste in. Snapshots show whatever was on screen, so avoid noting screens with personal data you don't want in a chat.

## Update and uninstall

### Update

Update the Mac first, then your apps. An older Redline on the Mac still delivers reports from a newer app, but may not read them fully.

- **Mac.** Run your install command again. It rebuilds Redline and restarts it. The curl command builds the newest `main`. With npx, ask for the latest version, or npx may reuse its earlier download:

  ```sh
  npx agent-redline-ios@latest
  ```

- **App.** In Xcode, choose File > Packages > Update to Latest Package Versions, then rebuild.

### Uninstall

```sh
npx agent-redline-ios uninstall
```

or

```sh
(f="$(mktemp)" && trap 'rm -f "$f"' EXIT && curl -fsSL https://raw.githubusercontent.com/mericksters13/agent-redline-ios/main/install.sh -o "$f" && bash "$f" uninstall)
```

This removes the command, the app, the login item, Redline's hooks and MCP entry, the line it added to `~/.zprofile`, and its cache in `~/Library/Caches/Redline`. The checklist lists anything it couldn't remove. Other tools' hooks and MCP servers stay, and so do:

- your reports, in `~/Library/Application Support/Redline`
- the `.before-redline` backups, next to the files they copied
- the worktrees and `report/` branches made for new chats, and the line Redline added to each repository's `.git/info/exclude`

In your app, remove the `.redline()` line and the package.

## Troubleshooting

`redline status` and the menu bar panel show what the Mac sees. Redline's log is `~/Library/Application Support/Redline/hub/hub.log`.

**The phone says "Saved on this iPhone. Couldn't reach the Mac".**
The app couldn't connect to Redline: Redline isn't running, the Mac is asleep or on a different network from the phone, or the app's Local Network access is off (turn it on in Settings > Privacy & Security > Local Network). The report stays on the phone and goes again when the app launches or comes to the foreground, or with the next Send. `redline status` shows the addresses apps use to reach the Mac.

**The panel shows a phone as Not reachable.**
Redline couldn't reach the phone over Xcode's device link: the phone is asleep, out of range or on a different network. Wake it. Redline keeps trying, and tries again at once when the phone wakes.

**The phone says "Not on the Mac yet: no Mac has set up this app", or the panel says No watched app installed.**
Redline hasn't found the app on that device yet. It looks for newly installed apps when it starts, when a chat for a new app opens, and every 30 minutes. To make it look now, click Quit in its panel and open `Redline.app` again from `~/Applications`. If it still doesn't find the app, check that a chat for the app's project is open (for Codex, trust "Report delivery" in `/hooks`, then send the chat a message) and that Xcode can reach the phone.

**Annotate mode says "SwiftUI elements may not be pickable".**
The kit couldn't turn on the automation mode SwiftUI needs (see [What ships in your app](#what-ships-in-your-app)), most likely because this iOS version removed the private function it uses. You can still select UIKit views, and the capture button still attaches the whole screen.

**macOS asks about your Documents folder again after you update Redline.**
The installer signs Redline with your Apple Development certificate when you have one it can use. Without one, macOS may ask again after each rebuild. Allow it.

**Reports for a Codex chat wait for your next message.**
The Codex app isn't installed, isn't running or doesn't answer. The Agents row in the panel says which. Open the Codex app. If it still doesn't answer after you reopen it, a Codex update may have changed how Redline reaches it: [update Redline](#update). If reports never arrive at all, open `/hooks` in Codex and trust "Report delivery". If you installed Codex after Redline, run `~/.local/bin/redline setup`.

**A notification says to run `claude auth login`.**
The `claude` command, which starts new Claude Code chats and reopens closed ones, isn't signed in or is too old for the Claude app. The report waits in the inbox and goes once the command is ready. Run `claude auth login`, or `~/.local/bin/redline setup`, which checks both.

**A report waits in the inbox.**
The panel says why, for example when several chats work in the same worktree and none was picked. Pick a chat in Send to for the next report. To give the waiting ones to a chat, ask it to call `check_messages` (a Claude Code chat started after the install) or to run `redline check` in the project folder.

**"Couldn't find devicectl."**
Install Xcode and select it: `sudo xcode-select -s /Applications/Xcode.app`.

## Command reference

| Command | What it does |
|---|---|
| `redline status` | Shows what Redline is doing, each phone's state and what's in the inbox. |
| `redline check` | Prints the reports waiting for this project's apps. Once printed, no other chat gets them. |
| `redline wait` | Waits for the next report for this project's apps, then prints it. |
| `redline setup` | Checks the `claude` command and adds the Codex hook. With `--no-input`, or without a terminal, it lists the commands for you to run instead of running them. |
| `redline remove` | Removes Redline's hooks. Other hooks stay. |
| `redline mcp` | The MCP server a Claude Code chat runs. It gives the chat the `check_messages` and `wait_for_message` tools. |
| `redline hub` | Redline without the menu bar app. |
| `redline app` | The menu bar app. Opening `Redline.app` does the same. |

`check`, `wait` and `mcp` take `--project <folder>`, and `--app <bundle ID>` for an app whose bundle ID can't be read from the project. `hub` and `app` take `--app <bundle ID>` to take reports for an app no chat works on.

## Contributing

To build, test, install your own checkout and send a change, see [CONTRIBUTING.md](CONTRIBUTING.md). How the code is written is in [docs/CODE_STYLE.md](docs/CODE_STYLE.md).

## Acknowledgements

The kit's walk of the accessibility tree and its automation switch follow the approach of [AnnotateKit](https://github.com/Connected-Mate/AnnotateKit) (MIT).

## License

Redline is released under the [MIT License](LICENSE).
