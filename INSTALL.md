# Installing Redline: instructions for coding agents

This file is for a coding agent, such as Claude Code or Codex, that a user asked to "install Redline and add it to this app". Follow the steps in order. The user's own guide is the [README](README.md).

Redline has two parts: a Mac side (the `redline` command and the `Redline.app` menu bar app) that one installer sets up, and a Swift package, `Redline`, that goes into the user's iOS app with one line, `.redline()`.

## Rules

- **Never ask for, type or handle credentials.** Signing in the `claude` command (`claude auth login`) and trusting the Codex hook are the user's to do. List them for the user at the end.
- **Never run `sudo`.** When the installer stops with a `sudo` command, give that command to the user, and run the installer again after they say it is done.
- **Don't run the installer as root**, and don't pass it `--no-start`: that option is for tests and CI.
- **Change only what these steps name** in the user's project: the package dependency and the `.redline()` line. No Info.plist keys, permissions, build settings or build phases are needed.

## 1. Run the installer

Run one of these from any folder. They run the same installer. `--no-input` makes sure it never waits for an answer: it lists what needs the user instead (it turns this on by itself when it sees Claude Code, Codex or CI, but pass it anyway).

```sh
npx --yes agent-redline-ios@latest --no-input
```

If `npx` is not installed, or npm can't find the package yet, download the script first and then run it. Don't pipe curl into bash: if the download fails, bash runs an empty script and exits 0, and you would think Redline is installed.

```sh
curl -fsSL https://raw.githubusercontent.com/mericksters13/agent-redline-ios/main/install.sh -o "${TMPDIR:-/tmp}/redline-install.sh" && /bin/bash "${TMPDIR:-/tmp}/redline-install.sh" --no-input
```

(`npx --yes github:mericksters13/agent-redline-ios --no-input` also works.)

What to expect:

- It builds Redline from source with Xcode, which takes a few minutes the first time and can take longer than a command timeout allows (Claude Code stops a foreground command after 10 minutes at most). Run it in the background, wait for it to exit, and then check the result: in Claude Code, use the Bash tool's `run_in_background` and wait for the notice that it finished; in Codex, raise the command timeout to 20 minutes or more.
- It writes outside the project: `~/.local/bin/redline`, `~/Applications/Redline.app`, `~/Library/LaunchAgents/com.agentredline.hub.plist`, `~/.zprofile` (one line, only when `~/.local/bin` is not on `PATH`), `~/.claude.json` (through `claude mcp add`), `~/.codex/hooks.json`, `~/Library/Caches/Redline` and `~/Library/Application Support/Redline`. If your sandbox blocks writes outside the project, ask the user to allow the command outside the sandbox, or to run it in their terminal and tell you when it has finished.
- It ends with a checklist marked Done, Needs you or Skipped, under the heading `Redline install checklist`. The same checklist is saved in `~/Library/Application Support/Redline/install-report.txt`, whose first line ends with the date and time of the run.
- **It worked** when the command exited with status 0 **and** printed `Redline install checklist`, or, if you lost the output, when `install-report.txt` starts with `Redline install checklist` and today's date. Exit status 0 alone is not enough. Items marked Needs you don't mean it failed.
- **It stopped** when the status is anything else, or the report starts with `Redline is not installed.`: the Stopped line names the problem and the one fix. Give the user the fix (for example `sudo xcodebuild -license accept`), wait until they have done it, and run the same command again.

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
- Version: the `main` branch (there are no version tags yet)
- Product: `Redline`; package identity: `agent-redline-ios`

## 3. Add the package to the app target

### XcodeGen (`project.yml`)

Add the package and the dependency, then regenerate the project:

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

```sh
xcodegen generate
```

Merge these into the existing `packages:` and the app target's `dependencies:`; don't add second copies of those keys.

### Tuist

If the project lists its packages in `Tuist/Package.swift`, add the dependency there:

```swift
.package(url: "https://github.com/mericksters13/agent-redline-ios.git", branch: "main"),
```

and add `.external(name: "Redline")` to the app target's `dependencies` in `Project.swift`. Then:

```sh
tuist install
tuist generate --no-open
```

If the project lists packages in `Project.swift` instead, add `.remote(url: "https://github.com/mericksters13/agent-redline-ios.git", requirement: .branch("main"))` to its `packages:` and `.package(product: "Redline")` to the app target's dependencies, then run `tuist generate --no-open`.

### Swift package app (`Package.swift`)

```swift
.package(url: "https://github.com/mericksters13/agent-redline-ios.git", branch: "main")
// in the app target's dependencies:
.product(name: "Redline", package: "agent-redline-ios")
```

### Plain Xcode project (`.xcodeproj`)

Adding a package means editing `project.pbxproj`, which Xcode normally writes itself. A mistake there can stop the project from opening. Work like this:

1. If the project folder is a git repository, check that `project.pbxproj` has no uncommitted changes, so your edit can be undone with `git checkout -- <path>/project.pbxproj`. Otherwise copy the file first.
2. If the `xcodeproj` Ruby gem is installed (`gem list xcodeproj`), use it to add the package; it writes the file the way Xcode does. Otherwise edit the file by hand. You need three new objects, each with a new unique 24-character hexadecimal ID: an `XCRemoteSwiftPackageReference` (the URL, with `requirement = { kind = branch; branch = main; }`), an `XCSwiftPackageProductDependency` (`package` set to that reference, `productName = Redline`), and a `PBXBuildFile` with `productRef` set to the product dependency. Then add the reference to the project's `packageReferences`, the product dependency to the app target's `packageProductDependencies`, and the build file to the `files` of the app target's Frameworks build phase.
3. Check the result: `xcodebuild -list -project <App>.xcodeproj` must succeed, and so must the build in step 5.
4. If anything fails, or you are not confident in the edit, restore the file and ask the user to add the package in Xcode instead: File > Add Package Dependencies, enter `https://github.com/mericksters13/agent-redline-ios.git`, choose the `main` branch, and add the `Redline` library to the app target. Tell them you will do the rest when they are done.

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

1. Every **Needs you** item from the installer's checklist, with its exact command or click. These are typically:
   - `claude auth login` (or `claude update`), when the `claude` command isn't signed in or is too old for the Claude app.
   - In Codex, open `/hooks` and trust "Report delivery".
   - Open a new terminal window, when the installer added `~/.local/bin` to `PATH`.
2. Start a new Claude Code chat in the project, or restart this one: a chat loads Redline's MCP server when it starts. A Codex chat registers the next time the user sends it a message.
3. Run the Debug build on a paired iPhone or a simulator. On an iPhone, allow the local network prompt the first time.
4. Tap the floating Redline button, tap an element, write a note and tap Send. The first time, pick this chat in Send to.

If the installer stopped and the user hasn't fixed it yet, say that first, with the fix.

To remove Redline later: `npx --yes agent-redline-ios@latest uninstall`, or download the script as in step 1 and run it with `uninstall`. Saved reports stay in `~/Library/Application Support/Redline`.
