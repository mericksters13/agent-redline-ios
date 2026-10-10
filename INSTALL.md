# Installing Redline: instructions for coding agents

This file is for a coding agent, such as Claude Code or Codex, that a user asked to "install Redline and add it to this app". Follow the steps in order. The user's own guide is the [README](https://github.com/mericksters13/agent-redline-ios#readme).

Redline has two parts: a Mac side (the `redline` command and the `Redline.app` menu bar app) that one installer sets up, and a Swift package, `Redline`, that goes into the user's iOS app with one line, `.redline()`.

## Rules

- **Never ask for, type or handle credentials.** Signing in the `claude` command (`claude auth login`) and trusting the Codex hook are the user's to do. List them for the user at the end.
- **Never run `sudo`.** When the installer stops with a `sudo` command, give that command to the user, then have them run the installer again.
- **If you do run the installer** at the user's request, don't run it as root, and don't pass it `--no-start`: that option is for tests and CI.
- **Change only what these steps name** in the user's project: the package dependency and the `.redline()` line. No Info.plist keys, permissions, build settings or build phases are needed.

## 1. Hand the user the Mac installer

Don't run the installer yourself. It downloads and runs code that changes the Mac outside the project, which agent safety checks (Claude Code's auto mode, Codex's sandbox) block or stop to ask about. It's the one step the user takes.

Once you've read this guide and found the app (step 2), your first message, before you change anything, says in a few lines:

- what you'll change in their project: the `Redline` package on the app target and `.redline()` on the root view;
- the one command for them to run in their own terminal, for the Mac side:

  ```sh
  npx agent-redline-ios
  ```

  It installs the `redline` command and the Redline menu bar app, and connects Claude Code and Codex. It builds from source with Xcode, so the first run takes a few minutes, and it ends with a checklist. `npx` needs Node.js 18 or later; without it, give them this instead, which downloads the same installer and runs it only when the download worked:

  ```sh
  (f="$(mktemp)" && trap 'rm -f "$f"' EXIT && curl -fsSL https://raw.githubusercontent.com/mericksters13/agent-redline-ios/main/install.sh -o "$f" && bash "$f")
  ```

Then carry on with steps 2 to 5 while they run it.

If the user asks you to run it anyway, run `npx --yes agent-redline-ios@latest --no-input` in the background (it can take longer than a foreground command may run) and wait for it to exit.

**Checking it finished.** The installer writes `~/Library/Application Support/Redline/install-report.txt`. An install that stops while replacing the earlier version, Agentic Debugging, writes it to `~/Library/Caches/Redline/install-report.txt` instead, so check both and use the newer. A report counts only when the file was modified after you handed over the command: compare its modification time, to the second (`stat -f '%Sm' -t '%Y-%m-%d %H:%M:%S' <file>`), with the time you sent your message. An older report is from an earlier run, so the user still has to run the installer.

- It worked when the report starts with `Redline install checklist`. Items marked Needs you don't mean it failed.
- It stopped when the report starts with `Redline is not installed.`: the Stopped line names the problem and its one fix, such as `sudo xcodebuild -license accept`. Give the user that fix and ask them to run the installer again.

## 2. Find the app's project

Look in the user's project folder for, in this order:

| Found | Project type |
|---|---|
| `project.yml` | XcodeGen |
| `Project.swift` or a `Tuist/` folder | Tuist |
| `*.xcodeproj` (with or without an `*.xcworkspace`) | Plain Xcode project |
| Only a `Package.swift` with an iOS app product | Swift package app |

Find the iOS app target and its `@main` `App` struct. Redline needs an app that targets iOS 18 or later and uses SwiftUI. If the deployment target is older, or the app has no SwiftUI root view, stop and tell the user rather than changing the deployment target.

The package details, for every project type:

- URL: `https://github.com/mericksters13/agent-redline-ios.git`
- Version: up to the next minor version from `0.1.1`, so a breaking 0.2 isn't picked up
- Product: `Redline`; package identity: `agent-redline-ios`

## 3. Add the package to the app target

### XcodeGen (`project.yml`)

Add the package and the dependency, then regenerate the project:

```yaml
packages:
  Redline:
    url: https://github.com/mericksters13/agent-redline-ios.git
    minorVersion: 0.1.1
targets:
  YourApp:
    dependencies:
      - package: Redline
        product: Redline
```

```sh
xcodegen generate
```

Merge these into the existing `packages:` and the app target's `dependencies:`; don't add second copies of those keys.

### Tuist

If the project lists its packages in `Tuist/Package.swift`, add the dependency there:

```swift
.package(url: "https://github.com/mericksters13/agent-redline-ios.git", .upToNextMinor(from: "0.1.1")),
```

and add `.external(name: "Redline")` to the app target's `dependencies` in `Project.swift`. Then:

```sh
tuist install
tuist generate --no-open
```

If the project lists packages in `Project.swift` instead, add `.remote(url: "https://github.com/mericksters13/agent-redline-ios.git", requirement: .upToNextMinor(from: "0.1.1"))` to its `packages:` and `.package(product: "Redline")` to the app target's dependencies, then run `tuist generate --no-open`.

### Swift package app (`Package.swift`)

```swift
.package(url: "https://github.com/mericksters13/agent-redline-ios.git", .upToNextMinor(from: "0.1.1"))
// in the app target's dependencies:
.product(name: "Redline", package: "agent-redline-ios")
```

### Plain Xcode project (`.xcodeproj`)

Adding a package means editing `project.pbxproj`, which Xcode normally writes itself. A mistake there can stop the project from opening. Work like this:

1. If the project folder is a git repository, check that `project.pbxproj` has no uncommitted changes, so your edit can be undone with `git checkout -- <path>/project.pbxproj`. Otherwise copy the file first.
2. If the `xcodeproj` Ruby gem is installed (`gem list xcodeproj`), use it to add the package; it writes the file the way Xcode does. Otherwise edit the file by hand. You need three new objects, each with a new unique 24-character hexadecimal ID: an `XCRemoteSwiftPackageReference` (the URL, with `requirement = { kind = upToNextMinorVersion; minimumVersion = 0.1.1; }`), an `XCSwiftPackageProductDependency` (`package` set to that reference, `productName = Redline`), and a `PBXBuildFile` with `productRef` set to the product dependency. Then add the reference to the project's `packageReferences`, the product dependency to the app target's `packageProductDependencies`, and the build file to the `files` of the app target's Frameworks build phase.
3. Check the result: `xcodebuild -list -project <App>.xcodeproj` must succeed, and so must the build in step 5.
4. If anything fails, or you are not confident in the edit, restore the file and ask the user to add the package in Xcode instead: File > Add Package Dependencies, enter `https://github.com/mericksters13/agent-redline-ios.git`, choose Up to Next Minor Version from `0.1.1`, and add the `Redline` library to the app target. Tell them you will do the rest when they are done.

## 4. Add `.redline()` to the root view

In the file with the app's `@main` `App` struct, import Redline and add `.redline()` to the root view inside `WindowGroup`:

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

Don't wrap it in `#if DEBUG`: in Release builds `.redline()` returns the view unchanged and the package compiles to an empty module. Add it once, on the outermost view of the main window.

## 5. Build Debug to confirm

Build the app's scheme in Debug for the simulator, with `-project` or `-workspace` as the project uses:

```sh
xcodebuild -scheme <AppScheme> -configuration Debug -destination 'generic/platform=iOS Simulator' build
```

If the project has its own build instructions (a Makefile, a script, or rules in its `AGENTS.md` or `CLAUDE.md`), follow those instead. Fix any error that comes from your change. You don't need to run the app.

## 6. Tell the user what is left

End with a short message that gives:

1. Every **Needs you** item from the installer's checklist (`install-report.txt`), with its exact command or click. These are typically:
   - `claude auth login` (or `claude update`), when the `claude` command isn't signed in or is too old for the Claude app.
   - In Codex, open `/hooks` and trust "Report delivery".
   - Open a new terminal window, when the installer added `~/.local/bin` to `PATH`.
2. After the Mac installer finishes, run `redline doctor` (or `~/.local/bin/redline doctor` if PATH is not ready) and pass on its **Incomplete** fixes and **Check yourself** steps. Completed checks have a green check mark; missing or incomplete steps have a red x. It does not change the Mac; exit `0` only means its automatic checks found no missing steps.
3. Start a new Claude Code chat in the project, or restart this one: a chat loads Redline's MCP server when it starts. A Codex chat registers the next time the user sends it a message.
4. Open Redline and allow Local Network and, when projects are there, Documents access. If Local Network was denied, enable Redline in System Settings > Privacy & Security > Local Network. Notifications are optional.
5. Run the Debug build on a simulator or a physical iPhone. For an iPhone, pair it with Xcode, accept trust prompts, and enable Developer Mode in Settings > Privacy & Security; restart and confirm Enable. Keep it on the Mac's local network and allow the app's Local Network prompt. If denied, enable the app in Settings > Privacy & Security > Local Network. After the first install, quit and reopen Redline to rescan.
6. Tap the floating Redline button, tap an element, write a note and tap Send. The first time, pick this chat in Send to. Confirm the note and snapshot arrive; neither the installer checklist nor doctor proves delivery.

If the user hasn't run the installer yet, or it stopped, say that first, with the command or the fix.

To remove Redline later, the user runs `npx agent-redline-ios uninstall`. Saved reports stay in `~/Library/Application Support/Redline`.
