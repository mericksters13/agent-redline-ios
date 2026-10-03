# iOSAgenticDebuggingKit instructions

These rules apply to every change in this repository.

## Task identity

- The Linear **Devex** team (`DEV`) owns the problem, acceptance criteria, and status: <https://linear.app/trailxyz/team/DEV>.
- Before changing files, identify or create the one active `DEV` issue that owns the work and read its acceptance criteria.
- Branch from an up-to-date `main`. Use Linear's generated branch name, or `<type>/dev-<number>-<short-slug>`.
- Use a dedicated worktree when another issue is already in progress in the root checkout. Preserve unrelated and uncommitted work.
- Commit messages and pull request titles start with `[DEV-<number>]`.

## Engineering rules

- Use plain language and no emoji in code, comments, documentation, commit messages, or UI strings.
- The kit ships in Debug builds only. Every source file except the public modifier is wrapped in `#if AGENTIC_DEBUGGING`, which `Package.swift` defines for debug configurations only. The public modifier must return the view unchanged without it.
- Private API use, such as the accessibility automation switch, stays inside `AGENTIC_DEBUGGING`.
- The Mac tool in `Sources/AgenticDebuggingTool` runs only on the Mac and never ships in an app, so it is wrapped in `#if os(macOS)` instead of `AGENTIC_DEBUGGING`.
- Keep platform-independent logic (button placement, element selection, report storage) free of UIKit so `swift test` runs on the Mac without a simulator.
- Do not add speculative abstractions, wrapper types, or dependencies. Every user-visible behavior must trace to the active issue.

## Verification

- `swift test` for logic.
- `xcodebuild -scheme iOSAgenticDebuggingKit -destination 'generic/platform=iOS Simulator' -derivedDataPath .build/xcode build` in Debug and Release. The Release product must not contain `AXSSetAutomationEnabled`.
- Simulator and device runs happen through a host app such as Trail or Tiny Tally and follow that repository's simulator rules.
- Physical-device behavior (gestures, haptics, the real accessibility tree) needs a device check; a simulator run does not prove it.

## Delivery

- Stage only issue-owned files and run `git diff --check` before commit.
- Never merge a pull request or move a Linear issue to Done or Canceled without explicit user approval.
