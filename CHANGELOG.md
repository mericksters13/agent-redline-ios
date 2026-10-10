# Changelog

Notable changes to Redline. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions follow [Semantic Versioning](https://semver.org/).

## [Unreleased]

## [0.1.6] - 2026-10-10

### Added

- Browse the selected element's nearby accessibility hierarchy. Tap the downward chevron beside its name to see the owning component and its children, with the selected element highlighted. Indented rows and vertical lines show ownership, and branch arrows expand or collapse children.
- `redline doctor` checks Mac setup for your first report: the running app, project access, report storage, Local Network access and a chat for the app. Access checks run in the Redline Mac app without contacting an iOS app. Completed checks have a green check mark; incomplete steps have a red x and a next action. Use `--project` and `--agent` to select the project and destination. Chats in another checkout of the same app count, and connection failures are distinguished from a missing chat.

### Changed

- The hierarchy replaces the note card's ancestor path and "Nothing larger to select" message. It stays anchored to the component originally touched while you browse, and Done restores the note editor without losing its draft or selected target.
- Opening, closing and folding the hierarchy animate only the container height. Reduce Motion disables the animation.

## [0.1.5] - 2026-10-10

### Fixed

- New Codex report chats open in the desktop app before the agent investigates the report, so you can answer questions and continue in the same chat. This fixes the "This is open in another app" lock during report delivery.

## [0.1.4] - 2026-10-09

### Fixed

- Opening the note keyboard keeps the captured app behind the selected element or drawing. The outline stays with the capture while the host app resizes, including when Cancel or Add note dismisses the keyboard.
- The Send to > Codex picker includes chats created through Codex. Internal reviews, automations and subagents remain excluded.

## [0.1.3] - 2026-10-07

### Added

- Draw on the screen to annotate. The pen in the annotate bar switches touches to drawing, with Undo and Done in the bar. Done numbers the drawing and opens the note card, which lists the named elements inside it. The report shows the strokes in the snapshot and lists those elements for the agent.
- A container with `.accessibilityElement(children: .contain)` and no identifier or label can be picked. It is named after what it holds, such as `"Beyond the sky" and 2 more`, in the note card and the report.

### Changed

- The note card shows the path from the outermost element enclosing your pick to the element you tapped, and tapping a step selects that element. It replaces the Larger and Smaller buttons, which showed only when there was somewhere to go. When nothing encloses the pick, the card says "Nothing larger to select".

## [0.1.2] - 2026-10-06

### Added

- A demo app in `Examples/RedlineDemo`: an Xcode project with `.redline()` on its root view, a UIKit screen and three planted UI bugs. It builds the kit from the same checkout and isn't part of the npm package.

### Fixed

- Redline picks up a simulator install as it happens. Every install moves the app's data container, so a first install, a reinstall or a Run from Xcode left the build without the hub's address, or the hub watching the old container. Send then saved the report on the simulator, and it reached your session only at Redline's next scan, up to 30 minutes later.

## [0.1.1] - 2026-10-06

### Added

- The menu bar panel has an Agents section. It shows whether reports can reach Claude Code and Codex right now, and what to do when they can't.
- When the build's worktree isn't on main, the phone's Send to picker says so under New chat.
- Annotate mode says "SwiftUI elements may not be pickable" when the kit can't turn on the accessibility mode SwiftUI needs.

### Changed

- Redline needs Xcode 26 or later (Swift 6.2); Xcode 16 couldn't build it. The installer stops on an older Swift and says how to fix it.
- Add the package up to the next minor version, so a breaking 0.2 isn't picked up.
- The README is rewritten for developers and matches the code. Deeper detail moved to [docs/HOW-IT-WORKS.md](docs/HOW-IT-WORKS.md).

### Fixed

- `redline` exits cleanly on SIGINT, SIGTERM and SIGHUP instead of crashing, including when the installer restarts the menu bar app.
- Scrolling the menu bar panel's report list is smoother: rows no longer carry tooltips, whose tracking areas were rebuilt on every frame.

## [0.1.0] - 2026-10-05

First public release.

[Unreleased]: https://github.com/mericksters13/agent-redline-ios/compare/0.1.6...HEAD
[0.1.6]: https://github.com/mericksters13/agent-redline-ios/compare/0.1.5...0.1.6
[0.1.5]: https://github.com/mericksters13/agent-redline-ios/compare/0.1.4...0.1.5
[0.1.4]: https://github.com/mericksters13/agent-redline-ios/compare/0.1.3...0.1.4
[0.1.3]: https://github.com/mericksters13/agent-redline-ios/compare/0.1.2...0.1.3
[0.1.2]: https://github.com/mericksters13/agent-redline-ios/compare/0.1.1...0.1.2
[0.1.1]: https://github.com/mericksters13/agent-redline-ios/compare/0.1.0...0.1.1
[0.1.0]: https://github.com/mericksters13/agent-redline-ios/releases/tag/0.1.0
