# Redline instructions

These rules apply to every change in this repository.

## Task identity

- One active issue owns each change: its problem, acceptance criteria, and status. It is either a maintainer's Linear issue in the `DEV` team, or a GitHub issue in this repository. Contributors without access to the maintainer's Linear use GitHub issues.
- Before changing files, identify or create the issue that owns the work and read its acceptance criteria.
- Branch from an up-to-date `main`. For a Linear issue, use Linear's generated branch name, or `<type>/dev-<number>-<short-slug>`. For a GitHub issue, use `<type>/gh-<number>-<short-slug>`.
- Use a dedicated worktree when another issue is already in progress in the root checkout. Preserve unrelated and uncommitted work.
- Commit messages and pull request titles start with `[DEV-<number>]` for a Linear issue, or `[GH-<number>]` for a GitHub issue.
- This repository is public. Tracked files, commit messages, and pull requests name nothing from the maintainer's private work: no private apps or repositories, no Linear workspace links, and no local paths.

## Engineering rules

- Use plain language and no emoji in code, comments, documentation, commit messages, or UI strings.
- The kit ships in Debug builds only. Every source file except the public modifier is wrapped in `#if REDLINE`, which `Package.swift` defines for debug configurations only. The public modifier must return the view unchanged without it.
- Private API use, such as the accessibility automation switch, stays inside `REDLINE`.
- The Mac tool in `Sources/RedlineTool` runs only on the Mac and never ships in an app, so it is wrapped in `#if os(macOS)` instead of `REDLINE`.
- Keep platform-independent logic (button placement, element selection, report storage) free of UIKit so `swift test` runs on the Mac without a simulator.
- Do not add speculative abstractions, wrapper types, or dependencies. Every user-visible behavior must trace to the active issue.

## Verification

- `swift test` for logic.
- `xcodebuild -scheme Redline -destination 'generic/platform=iOS Simulator' -derivedDataPath .build/xcode build` in Debug and Release. The Release product must not contain `AXSSetAutomationEnabled`.
- `xcodebuild -project Examples/RedlineDemo/RedlineDemo.xcodeproj -scheme RedlineDemo -configuration Debug -destination 'generic/platform=iOS Simulator' -derivedDataPath .build/demo build CODE_SIGNING_ALLOWED=NO` builds the demo app, as CI does.
- Simulator and device runs use the demo app in `Examples/RedlineDemo` as the default host for checking Redline changes. When a change needs another host app, follow that repository's simulator rules.
- Physical-device behavior (gestures, haptics, the real accessibility tree) needs a device check; a simulator run does not prove it.

## Delivery

- Stage only issue-owned files and run `git diff --check` before commit.
- Never merge a pull request, move a Linear issue to Done or Canceled, or close a GitHub issue without explicit user approval.
