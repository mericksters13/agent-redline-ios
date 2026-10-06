# Changelog

Notable changes to Redline. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions follow [Semantic Versioning](https://semver.org/).

## [Unreleased]

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

[Unreleased]: https://github.com/mericksters13/agent-redline-ios/compare/0.1.2...HEAD
[0.1.2]: https://github.com/mericksters13/agent-redline-ios/compare/0.1.1...0.1.2
[0.1.1]: https://github.com/mericksters13/agent-redline-ios/compare/0.1.0...0.1.1
[0.1.0]: https://github.com/mericksters13/agent-redline-ios/releases/tag/0.1.0
