# Contributing to Redline

Thanks for helping. This page covers what you need to build, test and send a change. How the code is written, and what reviewers look for, is in [docs/CODE_STYLE.md](docs/CODE_STYLE.md).

## What you need

- A Mac with macOS 15 or later.
- Xcode 16 or later. The package uses Swift tools version 6.0, so code must also compile with Swift 6.0 (Xcode 16.0); newer syntax such as trailing commas in argument lists or `@concurrent` is off limits.

The package has three parts:

- `Sources/Redline`: the iOS kit that apps add. Everything in it ships in Debug builds only.
- `Sources/RedlineTool`: the `redline` command and the Redline menu bar app. It runs on the Mac and never ships in an app.
- `Tests`: Swift Testing suites for both, plus a few XCTest performance tests.

## Build and test

```sh
swift build -Xswiftc -warnings-as-errors
swift test
swift test --sanitize=thread --filter RedlineToolTests
swift build -c release --product redline
```

Run the kit's tests in debug, the default. `swift test -c release` builds an empty kit test target and runs nothing.

`swift test` runs on the Mac, without a simulator. It covers the kit's platform-independent logic, the Mac tool, and contract tests that check the Mac reads exactly what the kit writes.

To build the menu bar app into a folder of your choice:

```sh
scripts/build-hub-app.sh <destination folder>
```

Without a folder, the script installs `Redline.app` in `~/Applications`.

## Install your checkout

To try a change on your own Mac, run the installer from your checkout. It builds and installs that checkout instead of downloading one:

```sh
git clone https://github.com/mericksters13/agent-redline-ios.git
cd agent-redline-ios
bash install.sh
```

Run it again after each change. It builds the checkout as it is, so `git pull` first to update. If you install the `redline` command by hand, copy it from the output of `swift build -c release --product redline`, as the installer does, not from `Redline.app`: macOS stops a copy taken out of the signed app bundle.

## Check the iOS build

The kit's UI code only compiles for iOS. Build it in Debug and in Release:

```sh
xcodebuild -scheme Redline -configuration Debug -destination 'generic/platform=iOS Simulator' -derivedDataPath .build/xcode build
xcodebuild -scheme Redline -configuration Release -destination 'generic/platform=iOS Simulator' -derivedDataPath .build/xcode build
```

Then confirm that the private accessibility symbol is in the Debug product and not in the Release one:

```sh
strings .build/xcode/Build/Products/Debug-iphonesimulator/Redline.o | grep -c AXSSetAutomationEnabled    # more than 0
strings .build/xcode/Build/Products/Release-iphonesimulator/Redline.o | grep -c AXSSetAutomationEnabled  # 0
```

Build the documentation, which must finish with no warnings:

```sh
xcodebuild docbuild -scheme Redline -destination 'generic/platform=iOS Simulator' -derivedDataPath .build/xcode
```

If your change touches `redline(sourceFile:)` or how the kit records file paths, build a host app in Release and confirm its binary holds no path from your Mac:

```sh
strings -a <Release host app binary> | grep "$HOME"    # nothing
```

A simulator run does not prove how gestures, haptics or the accessibility tree behave on a phone. If your change touches those, check it on a device and say so in the pull request.

## Format

The repository has a `.swift-format` configuration, and the formatter ships with the Swift toolchain. Before you commit:

```sh
swift format --in-place --recursive Sources Tests scripts Package.swift
swift format lint --strict --recursive --parallel Sources Tests scripts Package.swift
```

The lint must print nothing.

## Rules that keep apps safe

Redline runs inside other people's apps, so a few rules are strict:

- **Debug builds only.** `Package.swift` defines `REDLINE` for debug configurations only. Every file in `Sources/Redline` except `Redline.swift` is wrapped in `#if REDLINE`, and without it the public `redline()` modifier returns the view unchanged. Release and TestFlight builds get an empty module.
- **Private API stays inside `REDLINE`.** The accessibility automation switch is looked up at run time with `dlopen` and `dlsym`, inside `#if REDLINE`, and the code copes with the symbol being missing. Never link a private symbol by name.
- **Mac code stays on the Mac.** Files in `Sources/RedlineTool` are wrapped in `#if os(macOS)`.
- **Logic stays testable.** Placement, selection, comparison and storage logic imports Foundation or CoreGraphics, not UIKit, so `swift test` runs it on the Mac.
- **One public declaration.** `redline(sourceFile:)` is the whole public API. A new public symbol is an API decision; raise it in an issue first.
- **No new dependencies or speculative types.** Add a type or helper only when it replaces existing code in the same change.
- **Plain language, no emoji** in code, comments, documentation, commit messages and UI text.

## Releasing

The npm package `agent-redline-ios` is published by the "Publish to npm" workflow
(`.github/workflows/publish-npm.yml`) through npm trusted publishing, so there is no npm token to
keep. To release:

1. Set the new version in `package.json`, in `version` in `Sources/RedlineTool/main.swift` and in `scripts/build-hub-app.sh`, move the Unreleased entries in [CHANGELOG.md](CHANGELOG.md) under it, and merge that into `main`.
2. Publish a GitHub release whose tag is that version, such as `0.1.1`, without a `v`.

The workflow checks that the tag matches the version, then publishes with a provenance record.
A version can't be published twice, so a mistake means a new version.

## Pull requests

- Keep each pull request to one change, and stage only the files it needs.
- Run `git diff --check`, the build and test commands, the iOS builds, the documentation build and the format lint before you open it.
- Say what you checked and how, including any device checks and, for performance work, the numbers you measured.
- A change to the messages between the phone and the Mac, or to `report.json`, keeps older versions readable: rename a field only with a `CodingKeys` entry that keeps the old key, or, for `report.json`, raise `Report.version`, write the new key and keep reading the old one, as version 2 does for snapshots; and extend the contract tests in `Tests/RedlineToolTests/KitContractTests.swift`. A hub already installed can't read a newer version fully, so a version bump also says, in the pull request and in the README's update steps, that the Mac is updated before apps are rebuilt.
