# Changelog

Notable changes to Redline. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions follow [Semantic Versioning](https://semver.org/).

## [Unreleased]

### Changed

- Redline now needs Xcode 26 or later (Swift 6.2); Xcode 16 couldn't build it. The installer stops on an older Swift and says how to fix it.

## [0.1.1] - 2026-10-05

### Added

- The menu bar panel has an Agents section. It shows whether reports can reach Claude Code and Codex right now, and what to do when they can't.
- When the app was built from a worktree that isn't on main, the phone's Send to picker says so under New chat.
- Annotate mode says "SwiftUI elements may not be pickable" when the kit can't turn on the accessibility mode SwiftUI needs.

### Changed

- The README is shorter and matches the code. Deeper detail moved to [docs/HOW-IT-WORKS.md](docs/HOW-IT-WORKS.md).
- Add the package up to the next minor version, so a breaking 0.2 isn't picked up.

## [0.1.0] - 2026-10-05

First public release.

[Unreleased]: https://github.com/mericksters13/agent-redline-ios/compare/0.1.1...HEAD
[0.1.1]: https://github.com/mericksters13/agent-redline-ios/compare/0.1.0...0.1.1
[0.1.0]: https://github.com/mericksters13/agent-redline-ios/releases/tag/0.1.0
