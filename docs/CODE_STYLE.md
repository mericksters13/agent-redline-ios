# Redline code style

How code in this package is written and reviewed. Read it before your first pull request; reviewers use the same rules.

The package uses Swift 6.0 tools, the Swift 6 language mode, iOS 18 and macOS 15. [CONTRIBUTING.md](../CONTRIBUTING.md) has the build, test and format commands.

## How to use this guide

Each rule has an ID such as `C5` and a level.

- **must**: correctness, data and thread safety, public API quality, accessibility problems that block people, and performance problems that hang the UI, stall the hub or grow without limit. A must finding blocks merge.
- **should**: consistency, polish, and efficiency gains that do not change behavior. Fix these in code you are already changing, or in a separate cleanup change. A feature pull request does not fix should findings in unrelated files: keep each pull request to the files its change needs.

Reviewers report each finding on one line: `ID  path:line  what is wrong  suggested fix`.

The checks are starting points. A grep hit is not always a finding, and a clean grep does not prove anything. Read the code.

Order of precedence: `AGENTS.md` comes first, then this guide, then the outside guides it cites. When outside guides disagree, this guide picks one option and records the choice in [Decisions](#decisions).

Redline runs inside other people's apps. Its main-thread time, memory and wakeups count against the host app, and the Mac hub runs all day. Hold both to a higher bar than ordinary app code.

Section prefixes:

| Prefix | Section |
|---|---|
| A | Architecture and API surface |
| C | Concurrency |
| U | SwiftUI |
| P | Performance |
| E | Swift idioms and error handling |
| S | Style and consistency |
| T | Tests and package hygiene |

Baseline: `swift-tools-version: 6.0` means the Swift 6 language mode for every target and a compiler floor of Swift 6.0 (Xcode 16.0). The maintainer builds with a newer compiler, so syntax and APIs newer than that floor compile locally and break for users. They are off limits until the tools version is raised on purpose (T5).

[Quick scan](#quick-scan) at the end collects the fastest checks.

## Decisions

Outside guides disagree on these points. This is the choice for Redline.

| Topic | Choice | Reason |
|---|---|---|
| Formatter | swift-format (`swift format`), config checked in | It ships with every Swift 6 toolchain, so it adds no dependency (AGENTS.md). SwiftFormat would need one. |
| Indentation | 4 spaces. `#if` file wrappers do not indent their contents. | The code already does this everywhere. Google, Airbnb and swift-format's default of 2 spaces would change every line. |
| Line length | 120 | It matches 4-space code. Google and Airbnb use 100 with 2 spaces. |
| Wrapped calls | Each argument or parameter on its own line, closing parenthesis on its own line (`lineBreakBeforeEachArgument`) | A wrapped call reads as a list and diffs one argument per line. swift-format does not align continuation lines, so the older aligned style cannot be kept by the tool (S2). |
| Access level on extensions | On each declaration, never on the extension | This is the choice of Google, Airbnb and swift-format. SwiftFormat's default is the opposite. On a public SDK, a public symbol should say so where it is declared. |
| One-line bodies | Allowed for one simple statement that fits on the line (Google) | Airbnb wraps every body. The code relies on short one-line exits, which read well, so only compound and long ones are wrapped. |
| MARK headings | By feature: `// MARK: - Delivery` | The code groups its MARKs by feature. Airbnb groups by access level instead. |
| Several trailing closures | Use the trailing form, one closure per line | SwiftUI APIs are designed this way (SE-0279). The older advice from Google and Kodeco to label closures inside the parentheses comes from before Swift 5.3. |
| `self.` | Leave it out unless the compiler requires it or a name is shadowed | All the guides agree. Kodeco's advice to write `self` in escaping closures has been out of date since SE-0269 and SE-0365. |
| Stored property types | Inferred from the right-hand side (Airbnb) | This is what the code does. SwiftFormat's default of `infer-locals-only` would flip it. |
| Current date | `.now` (or `Date.now` when the type is not known) | The kit and the Mac tool both use it, so dates read the same everywhere. |
| `try!` in tests | Not allowed (Airbnb) | Google allows it, but a crash ends the whole test run instead of failing one test. |
| Test framework | Swift Testing. XCTest only for `measure(metrics:)` performance tests. | Swift Testing has no performance API. |
| Test names | Standard identifiers such as `snapsToTheNearestSideEdge` | Raw identifier names need Swift 6.2 (SE-0451). That is above the compiler floor. |
| Leaving the main actor | Call a `nonisolated async` function. Not `Task.detached`. | This is current Apple and Swift guidance (SE-0338, SE-0461). The 2022 advice to offload work with detached tasks is out of date. |
| Locks | `Mutex` from Synchronization | It is available from iOS 18 and macOS 15, which are exactly the package minimums (SE-0433). |
| Typed throws | Internal code only | SE-0413 and the Swift book: untyped `throws` stays the default. |
| Doc comments | Required on public declarations, encouraged on internal ones | Apple asks for docs on every declaration and Google asks for them on public ones. Nearly every type in the package already has one. |

---

## A. Architecture and API surface

### A1. Kit code compiles only in Debug, Mac code only on macOS

**Level:** must

**Rule:** Wrap every file in `Sources/Redline` except `Redline.swift` in `#if REDLINE` (or `#if REDLINE && canImport(UIKit)`), wrap every file in `Sources/RedlineTool` in `#if os(macOS)`, and have the public modifier return the view unchanged when `REDLINE` is not defined.

**Why:** Release and TestFlight builds of host apps must get an empty module, with no overlay, no private API and no permission prompts. `Package.swift` defines `REDLINE` for debug configurations only. The Mac tool never ships in an app.

```swift
// Do
#if REDLINE && canImport(UIKit)
import UIKit
// ...
#endif

// Don't
import UIKit  // No guard: this file compiles into every host app's Release build.
```

**Check:** `grep -L '^#if REDLINE' Sources/Redline/*.swift` prints only `Redline.swift`. `grep -L '^#if os(macOS)' Sources/RedlineTool/*.swift` prints nothing. T4 checks the Release product.

**Source:** `AGENTS.md` (Engineering rules); `Package.swift`

### A2. Private API is looked up at run time, inside REDLINE only

**Level:** must

**Rule:** Reach private API, such as `AXSSetAutomationEnabled`, only through `dlopen` and `dlsym` inside `#if REDLINE`, and handle the symbol being missing.

**Why:** App review scans Release binaries for private symbols, and a private symbol can vanish in any OS update. `AccessibilityTree.enableAutomation()` follows this pattern, including a fallback name.

```swift
// Do (inside #if REDLINE)
guard let handle = dlopen("/usr/lib/libAccessibility.dylib", RTLD_NOW),
    let symbol = dlsym(handle, "AXSSetAutomationEnabled") ?? dlsym(handle, "_AXSSetAutomationEnabled")
else { return }

// Don't
@_silgen_name("AXSSetAutomationEnabled")  // Linked by name, and an underscored attribute (A9).
func setAutomationEnabled(_ value: Int32)
```

**Check:** `grep -rn 'dlsym\|@_silgen_name' Sources` hits only files wrapped in `#if REDLINE`. T4 checks that the Release product does not contain the symbol name.

**Source:** `AGENTS.md`; <https://github.com/swiftlang/swift/blob/main/docs/ReferenceGuides/UnderscoredAttributes.md>

### A3. The public surface is one modifier

**Level:** must

**Rule:** Keep `redline(sourceFile:)` as the only public declaration, write `public` on the member rather than on its extension, and treat any new public symbol as a reviewed API decision.

**Why:** Every public symbol is a promise to users, and it appears in their autocomplete and docs. An access modifier on an extension becomes the default for every member in it, so a helper added later inside `public extension View` is public without anyone deciding that.

```swift
// Do
extension View {
    public func redline(sourceFile: StaticString = #filePath) -> some View { ... }
}

// Don't
public extension View {
    func redline(sourceFile: StaticString = #filePath) -> some View { ... }
    func redlineMarker() -> some View { ... }  // Now public too, by accident.
}
```

**Check:** `grep -rnE '\b(public|open) (func|var|let|struct|class|enum|actor|extension|init|typealias|protocol)\b' Sources/Redline` finds exactly the one declaration and no `public extension`. Before each tagged release, run `swift package diagnose-api-breaking-changes <last-tag>`.

**Source:** <https://docs.swift.org/swift-book/documentation/the-swift-programming-language/accesscontrol/#Extensions>; <https://google.github.io/swift/#access-levels>; <https://github.com/airbnb/swift#extension-access-control>

### A4. The caller's file path stays out of Release binaries

**Level:** must

**Rule:** Split the public modifier with `#if`: the Debug version keeps `#filePath` and does no work in the modifier body, and the Release version is marked `@inlinable` so the unused path is optimized away. Everywhere else, use `#fileID`, and justify any other `#filePath` in a comment.

**Why:** A default argument is evaluated in the caller's module. A scratch experiment built a host package with `swift build -c release` and found the absolute path of the file that calls `.redline()`, including the developer's user name, in the binary, even though the Release modifier just returns `self`. When the Release declaration was marked `@inlinable`, the path disappeared. The guidelines prefer `#fileID` in production for privacy and size. Redline does need the full path in Debug to find the worktree, so that is the one exception. An earlier version also wrote a global each time the host's root `body` ran (U1). Passing the value into the hook, which turns it into a string once, removes that side effect.

```swift
// Do
extension View {
    #if REDLINE && canImport(UIKit)
    /// Adds the Redline overlay to this view's scene in Debug builds.
    /// (full doc comment, see A5)
    public func redline(sourceFile: StaticString = #filePath) -> some View {
        background(SceneHook(sourceFile: sourceFile).allowsHitTesting(false))  // Made into a string once.
    }
    #else
    /// Returns this view unchanged. Inlined so the caller's file path is not kept in the binary.
    @inlinable
    public func redline(sourceFile: StaticString = #filePath) -> some View { self }
    #endif
}

// Don't
func redline(sourceFile: StaticString = #filePath) -> some View {
    #if REDLINE && canImport(UIKit)
    BuildIdentity.sourceFile = "\(sourceFile)"  // Global write on every host body update.
    return background(SceneHook().allowsHitTesting(false))
    #else
    self  // Argument ignored, but the caller has already embedded the absolute path.
    #endif
}
```

**Check:** Build a host app in Release, then run `strings -a <app binary> | grep "$HOME"`. It must find nothing. The experiment used SwiftPM on macOS, so confirm the result on an iOS Release archive. `grep -rn '#filePath\|#file\b' Sources` finds only this modifier, unless a comment explains why `#fileID` is not enough.

**Source:** <https://www.swift.org/documentation/api-design-guidelines/#parameter-names>; <https://github.com/swiftlang/swift-evolution/blob/main/proposals/0274-magic-file.md>; <https://github.com/airbnb/swift#no-filepath-literal>

### A5. Every public declaration has a complete DocC comment

**Level:** must

**Rule:** Document each public declaration with a summary of one sentence fragment, a discussion of side effects and limits, `- Parameter` or `- Parameters:`, `- Returns:` and `- Throws:` where they apply, with the comment placed above any attributes.

**Why:** The doc comment is the first thing a user reads in Xcode and on the package's documentation page. DocC uses the first paragraph as the summary and asks for about 150 characters or fewer, in plain text without symbol names. The comment on `redline(sourceFile:)` is the model: it explains zero configuration, Release behavior, attaching twice and more than one scene, and has `- Parameter` and `- Returns:`.

```swift
// Do
/// Adds the Redline overlay to this view's scene in Debug builds.
///
/// Attach it once, at the app's root view. Attaching it again in the same scene
/// has no further effect. In Release builds, including TestFlight, nothing is
/// installed and no permissions are needed.
///
/// - Parameter sourceFile: Leave it out. The compiler fills it in, and the Mac uses it
///   to tell which project folder the app was built from.
/// - Returns: This view, with the overlay installed behind it in Debug builds.

// Don't
/** Installs redline */
@MainActor public func redline(sourceFile: StaticString = #filePath) -> some View
```

**Check:** The swift-format rules `AllPublicDeclarationsHaveDocumentation`, `BeginDocumentationCommentWithOneLineSummary` and `ValidateDocumentationComments` are on in `.swift-format` and report nothing. `xcodebuild docbuild -scheme Redline -destination 'generic/platform=iOS Simulator' -derivedDataPath .build/xcode` finishes with no documentation warnings. A Bool or optional return must say when it is false or nil.

**Source:** <https://www.swift.org/documentation/docc/writing-symbol-documentation-in-your-source-files>; <https://www.swift.org/documentation/api-design-guidelines/#write-doc-comment>; <https://google.github.io/swift/#parameter-returns-and-throws-tags>; <https://github.com/airbnb/swift#doc-comments-before-attributes>

### A6. Ship a documentation catalog

**Level:** should

**Rule:** Keep the landing page of the `Sources/Redline/Redline.docc` catalog current: it covers setup, the Mac tool, and the promise that Release builds compile the kit out.

**Why:** A catalog gives the package a front page in Xcode and on Swift Package Index (with a `.spi.yml`). DocC is part of the toolchain, so the catalog adds no dependency.

```markdown
<!-- Do: Redline.docc/Redline.md -->
# ``Redline``

Point at what is wrong in a running app and send it to the agent chat that built it.

## Overview

Attach ``SwiftUICore/View/redline(sourceFile:)`` once, at the root view. ...
```

```text
Don't: leave the package page as an automatically generated list of one symbol.
```

**Check:** `xcodebuild docbuild` produces a landing page with an overview and no warnings.

**Source:** <https://www.swift.org/documentation/docc/documenting-a-swift-framework-or-package>; <https://github.com/SwiftPackageIndex/PackageList>

### A7. Public concurrency annotations are minimal and exact

**Level:** must

**Rule:** Leave `redline()` main-actor isolated through `View`, with no `nonisolated` or `@preconcurrency`. State `Sendable` explicitly on any future public type. Use `@preconcurrency import` only for a module that has not adopted concurrency, with a comment.

**Why:** Swift does not infer `Sendable` for public types, because the conformance is a promise to clients. Adding `Sendable` requirements or `@Sendable` closure parameters later breaks source compatibility. An unneeded `@preconcurrency` hides diagnostics, and Swift 6 adds run-time isolation checks for preconcurrency code (SE-0423).

```swift
// Do
extension View {
    // Main actor through View. Returns self unchanged without REDLINE.
    public func redline(sourceFile: StaticString = #filePath) -> some View { ... }
}

// Don't
@preconcurrency import Network  // Network is already annotated; this only hides diagnostics.
public struct ReportSummary { ... }  // Public and silently not Sendable.
```

**Check:** `grep -rn '@preconcurrency' Sources` is empty, or each hit names the module and the reason. The build shows no "unnecessary @preconcurrency" warning.

**Source:** <https://www.swift.org/migration/documentation/swift-6-concurrency-migration-guide/libraryevolution/>; <https://developer.apple.com/videos/play/wwdc2024/10169/>; <https://github.com/swiftlang/swift-evolution/blob/main/proposals/0337-support-incremental-migration-to-concurrency-checking.md>

### A8. Imports are internal by default

**Level:** should

**Rule:** Enable `InternalImportsByDefault` for the Redline target and write `public import` only where a public signature needs it, which today means only SwiftUI in `Redline.swift`.

**Why:** In the Swift 5 and 6 language modes, imports are public by default, so it is easy to expose a dependency by naming one of its types in a public declaration. With internal imports, the compiler rejects any public API that uses a UIKit, Network, Photos or os type, which locks in A3. A future language mode makes this the default anyway.

```swift
// Do
// Package.swift
.target(
    name: "Redline",
    swiftSettings: debugOnly + [.enableUpcomingFeature("InternalImportsByDefault")]
)

// Redline.swift
public import SwiftUI

// Don't
// Plain `import UIKit` and `import Network` in every file, and nothing stops a later
// public API from taking an NWEndpoint or a UIImage.
```

**Check:** `grep -rn '^public import' Sources/Redline` lists only `public import SwiftUI` in `Redline.swift`.

**Source:** <https://github.com/swiftlang/swift-evolution/blob/main/proposals/0409-access-level-on-imports.md>

### A9. No underscored attributes. Share code with `package` access.

**Level:** must

**Rule:** Do not use `@_spi`, `@_implementationOnly`, `@_exported`, `@_silgen_name` or underscore-prefixed public names. Share code between targets with `package` access, and reach internals from tests with `@testable import`.

**Why:** The compiler's reference strongly discourages underscored attributes outside the Swift project, because their meaning can change. `package` (SE-0386) exists for exactly this purpose: visible to the other targets in the package, hidden from clients. Kit code is Debug-only while the Mac tool also builds in Release, so code shared between them needs care. Often a contract test (A12) is the simpler option.

```swift
// Do
package struct ReportOffer: Codable, Sendable { ... }  // Used by Redline and RedlineTool.

// Don't
@_spi(Mac) public struct ReportOffer: Codable, Sendable { ... }
```

**Check:** `grep -rnE '@_[a-zA-Z]|public (func|var|let|struct|class|enum) _' Sources` is empty. Another target uses every `package` declaration; otherwise it should be internal.

**Source:** <https://github.com/swiftlang/swift-evolution/blob/main/proposals/0386-package-access-modifier.md>; <https://github.com/swiftlang/swift/blob/main/docs/ReferenceGuides/UnderscoredAttributes.md>

### A10. No speculative types, wrappers or dependencies

**Level:** must

**Rule:** Add a new type, protocol, helper or package dependency only when it replaces existing code in the same change, such as code repeated in two or more places, a `Bool?` with three meanings, an untyped dictionary, or a stored tuple. Never add one for a use you expect later.

**Why:** AGENTS.md forbids speculative abstractions, wrapper types and dependencies. Several rules in this guide suggest new types (E1, E5, P3, E11, S17). Each one passes this test only because it replaces code that already exists. Tools that ship with the toolchain, such as swift-format and DocC, are not dependencies.

```text
Do:    Replace the hand-written Process runners with one Command.run helper (P3), in one change.
Don't: Add a ReportTransport protocol with one conformer "in case Bluetooth comes later".
Don't: Add swift-subprocess to Package.swift to run git.
```

**Check:** For every new type or helper, the pull request names the existing code it replaces, and that code is gone in the same diff. `Package.swift` has no `dependencies:`.

**Source:** `AGENTS.md` (Engineering rules)

### A11. Platform-independent logic stays free of UIKit

**Level:** must

**Rule:** Keep geometry, placement, selection, comparison, composition and storage logic in files that import only Foundation, CoreGraphics or other cross-platform frameworks, so `swift test` runs it on the Mac.

**Why:** AGENTS.md requires this, so that logic can be tested without a simulator. These include `AttachmentPlacement`, `ElementSelection`, `FloatingButtonPlacement`, `HubLink`, `NoteCardPlacement`, `SnapshotComparison`, `ReportDelivery`, `ReportStore`, `ReportSummary`, `ScreenComposition` and `ScreenshotSuggestion`, and each has a test file.

```swift
// Do (FloatingButtonPlacement.swift)
#if REDLINE
import CoreGraphics
static func snapped(_ point: CGPoint, within area: CGRect) -> CGPoint { ... }
#endif

// Don't
import UIKit
static func snapped(_ point: CGPoint, within insets: UIEdgeInsets) -> CGPoint  // Needs a simulator to test.
```

**Check:** `grep -ln 'import UIKit\|canImport(UIKit)' <the files above>` prints nothing. `swift test` passes on the Mac. New placement or selection logic goes in a file of this kind, with tests.

**Source:** `AGENTS.md` (Engineering rules)

### A12. Wire and file formats are API

**Level:** must

**Rule:** Treat every Codable type that crosses the network or sits on disk as public API: rename a property only with a `CodingKeys` entry that keeps the old key, change both sides of the phone-to-Mac protocol in one commit, keep a test that round-trips each message between the kit and the Mac, and make sure an unknown enum value cannot make a whole file unreadable.

**Why:** A phone running an older kit talks to a newer hub, and the reverse, and drafts written by one kit version are read by the next. The kit's `HubLink` and the Mac's `HubMessage` declare the same messages in two modules, so `KitContractTests` writes each message and `report.json` with one side and reads them with the other. A closed `String` enum is the trap to avoid: one unknown case fails decoding of a whole draft array, which is why an unknown `Annotation.Kind` falls back to a known case. Combined with `try?` (E2), that would be data loss.

```swift
// Do
struct Chat: Codable, Equatable, Sendable, Identifiable {
    var id: String
    var isSameWorktree: Bool

    private enum CodingKeys: String, CodingKey {
        case id
        case isSameWorktree = "sameWorktree"  // Wire name kept for older apps and hubs.
    }
}

// Don't
struct Chat: Codable {
    var isSameWorktree: Bool  // Renamed without CodingKeys: older apps can no longer decode chat lists.
}
```

**Check:** Any rename of a stored property on a Codable type in `HubLink`, `HubMessage`, `Report`, `ReportStore` or the Mac's state files comes with a `CodingKeys` entry or a migration in the same diff. `Tests/RedlineToolTests/KitContractTests.swift` (its target depends on both `Redline` and `RedlineTool`, which both build on the Mac in Debug) encodes each message with the kit's type, decodes it as the Mac's type, and back; a new message or report field gets a case there. A change to the shape of a message adds a version field or a new message type, as `Report.version` does for `report.json`. A key renamed on purpose raises that version, is written only under its new name and is still read under its old one, as version 2 does for `snapshots` and `snapshot`.

**Source:** <https://developer.apple.com/documentation/foundation/encoding-and-decoding-custom-types#Choose-Properties-to-Encode-and-Decode-Using-Coding-Keys>

### A13. One idea, one type, one name

**Level:** should

**Rule:** Within a module, name each type by its role, never reuse a top-level type name for a nested type, and never keep two hand-copied types for the same thing unless a test ties them together.

**Why:** When the same name means two things depending on where you read it, readers and the compiler resolve it differently. RedlineTool once had a top-level `Address` (the chat a report goes to) beside `HubMessage.Address` (the hub's network address); the first is now `ReportRecipient`. The kit and the Mac tool each keep one `Once<T>`, which is fine because they are separate modules.

```swift
// Do
/// The chat a report is for: the one that built the app it came from.
struct ReportRecipient: Codable, Equatable, Sendable {
    var chat: String
    var agent: String
    var folder: String
}

// Don't
struct Address: Codable { var chat: String; var agent: String; var folder: String }
enum HubMessage { struct Address: Codable { var device: String; var port: UInt16 } }  // Same module.
```

**Check:** `grep -rhoE '(struct|enum|class|actor) [A-Z][A-Za-z]*' Sources/RedlineTool | awk '{print $2}' | sort | uniq -d` prints nothing, and the same for `Sources/Redline`. A type whose doc says "must match X" is a finding unless a test enforces the match.

**Source:** <https://www.swift.org/documentation/api-design-guidelines/#name-according-to-roles>

---

## C. Concurrency

### C1. Async code never blocks its thread

**Level:** must

**Rule:** Inside an async function, a `Task` or `.task`, do not call anything that blocks, including `Process.waitUntilExit`, `readDataToEndOfFile`, semaphore or group waits, `sleep`, SQLite, large file writes, directory scans or `queue.sync` onto a queue that does such work. Send that work to a Dispatch queue you own and resume with a continuation.

**Why:** The cooperative thread pool has about one thread per CPU core and does not add threads when one blocks, so one blocked task stalls every other task, including the hub's other connections. On the main actor, Apple's tools report a hang after 250 ms. A `nonisolated async` function still runs on the cooperative pool, so it is not a place for blocking calls either.

```swift
// Do: the hub owns a serial queue for blocking work.
func chats(_ request: HubMessage.ChatsRequest) async -> HubMessage.ChatList {
    await withCheckedContinuation { continuation in
        directoryQueue.async { continuation.resume(returning: self.chatsNow(request)) }
    }
}

// Don't
Task {
    // Runs on the cooperative pool. ChatDirectory.list reads SQLite, scans folders and runs git.
    _ = await lines.send(HubMessage.encode(hub.chats(request)))
}
let ids = queue.sync { Array(watched.keys) }  // Reached from @MainActor refresh().
```

**Check:** For every async function and `Task` closure, follow the synchronous callees. `grep -rnE 'waitUntilExit|readDataToEndOfFile|\.wait\(|usleep|Thread\.sleep|sqlite3_|Data\(contentsOf|\.sync \{' Sources` and confirm that async code cannot reach any hit. Run the tool and its tests once with `LIBDISPATCH_COOPERATIVE_POOL_STRICT=1`; a hang there means a blocking call. Profile with the Hangs and Swift Concurrency instruments while a report arrives.

**Source:** <https://developer.apple.com/videos/play/wwdc2021/10254/>; <https://developer.apple.com/videos/play/wwdc2022/110350/>; <https://developer.apple.com/documentation/xcode/understanding-hangs-in-your-app>

### C2. Thread-parking waits only in plain Dispatch or command-line code

**Level:** must

**Rule:** Use `DispatchSemaphore`, `DispatchGroup.wait` and condition waits only in pure Dispatch code or synchronous command-line entry points, never where a `Task` can reach them and never for long waits on a concurrent queue, and comment each wait with the thread it parks and for how long.

**Why:** Semaphores hide a dependency from the Swift runtime, so they are unsafe with Swift concurrency. On a concurrent queue, each blocked worker makes GCD start another thread, which can grow without limit. That is why the MCP server runs each `wait_for_message` call, which can wait up to 600 seconds, on a thread of its own rather than on a concurrent queue.

```swift
// Do: the inbox's DispatchSource feeds an AsyncStream, so the wait suspends.
for await _ in inboxChanges(for: chat.bundleIDs) {
    if !InboxQueue.waiting(for: chat.bundleIDs, paths: paths).isEmpty { return true }
}

// Acceptable, in synchronous command-line code only:
// Runs on `work` (a Dispatch queue), never from a Task. Parks one GCD thread
// for at most `longestWait` seconds.
_ = waiter.signal.wait(timeout: .now() + left)

// Don't
func waitForReport() async -> Bool {
    let semaphore = DispatchSemaphore(value: 0)
    Task { await something(); semaphore.signal() }
    semaphore.wait()  // Blocks a cooperative thread waiting on another task.
    return true
}
```

**Check:** `grep -rnE 'DispatchSemaphore|DispatchGroup|\.wait\(|attributes: \.concurrent' Sources Tests`. Trace the callers of each wait: none is async or `@MainActor`, and the comment states the worst case.

**Source:** <https://developer.apple.com/videos/play/wwdc2021/10254/>; <https://developer.apple.com/videos/play/wwdc2017/706/>

### C3. Choose the isolation tool by how the state is used

**Level:** must

**Rule:** Use `@MainActor` for UI state, an actor for shared non-UI state that async code calls into, a `Mutex` for state that synchronous callbacks must read immediately, and a serial `DispatchQueue` for work that must run in order or that blocks. Do not convert working queue code to actors for style.

**Why:** Actors are a good default but are not FIFO and must not run blocking calls, because those would move onto the cooperative pool. Network, FSEvents and signal callbacks are synchronous and need an answer now. `PhoneLink`'s serial queue for one devicectl call at a time is a correct use of a queue.

```swift
// Do
// Blocking devicectl calls for one phone, one at a time, in order.
private let queue = DispatchQueue(label: "Redline.phone.\(phone.udid)", target: PhoneLink.devices)

// Don't
actor PhoneLink {
    func giveAddress() {
        _ = devicectl.write(...)  // waitUntilExit on the cooperative pool, inside an actor.
    }
}
```

**Check:** For each new type with shared state, the pull request says which of the four it uses and why. Reject an actor that wraps blocking calls, and a lock around state that only async code touches.

**Source:** <https://github.com/swiftlang/swift-evolution/blob/main/proposals/0433-mutex.md>; <https://developer.apple.com/videos/play/wwdc2022/110351/>; <https://www.swift.org/migration/documentation/swift-6-concurrency-migration-guide/commonproblems/>

### C4. `@unchecked Sendable` is a last resort and is documented

**Level:** must

**Rule:** Prefer, in order, a value type, `@MainActor`, an actor, then a final class with only `let` properties whose mutable state lives in a `Mutex`. When `@unchecked Sendable` remains, add a `Thread safety:` comment that names the lock or queue guarding each mutable property, and narrow the opt-out to single properties with `nonisolated(unsafe)` where you can.

**Why:** The compiler checks nothing on an `@unchecked` type, so every mutable property becomes the reviewer's job. The package has 8 such opt-outs (6 `@unchecked Sendable`, 2 `nonisolated(unsafe)`), and each comment says what protects what, or why the value is safe.

```swift
// Do
/// Thread safety: `buffer` is read and written only on `queue`. The connection is
/// itself Sendable, and everything else is a `let`.
final class Line: Sendable {
    private let connection: NWConnection
    private let queue = DispatchQueue(label: "Redline.link.line", target: HubLink.network)
    nonisolated(unsafe) private var buffer = Data()
}

// Don't
final class Hub: @unchecked Sendable {
    private let lock = NSLock()
    private var tokens: [String: String] = [:]  // Guarded by lock.
    private var listener: HubListener?          // Guarded by nothing; undocumented.
}
```

**Check:** `grep -rn '@unchecked Sendable\|nonisolated(unsafe)' Sources | wc -l` must not grow from 8. Each hit has a `Thread safety:` comment, and every `var` matches a guard named in it. A new `@unchecked` conformance needs a stated reason in the pull request.

**Source:** <https://www.swift.org/migration/documentation/swift-6-concurrency-migration-guide/commonproblems/>; <https://github.com/airbnb/swift#unchecked-sendable>

### C5. Guard shared mutable state with `Mutex`

**Level:** must

**Rule:** Protect shared mutable state with `Mutex` from the Synchronization module instead of an `NSLock` beside a separate `var`, group the guarded fields into one `State` struct in one `Mutex`, and pass `inout State` to helpers instead of locking again.

**Why:** `Mutex` is available from iOS 18 and macOS 15, which are exactly the package minimums. It ties the lock to the data, so the state cannot be touched without the lock, and it is `Sendable` whatever it holds. A class with only `let` properties and a `Mutex` is checked `Sendable` with no `@unchecked`. `Mutex` is not recursive, so the current "called with the lock held" helper convention becomes `inout` parameters.

```swift
// Do
import Synchronization

enum ClaudeCLI {
    private struct Check {
        var isReady: Bool
        var at: Date
    }

    private static let lastCheck = Mutex<Check?>(nil)

    static func isReady() -> Bool {
        if let check = lastCheck.withLock({ $0 }), Date.now.timeIntervalSince(check.at) < 60 {
            return check.isReady
        }
        let isReady = computeIsReady()  // Runs the process outside the lock.
        lastCheck.withLock { $0 = Check(isReady: isReady, at: .now) }
        return isReady
    }
}

// Don't
private static let lock = NSLock()
nonisolated(unsafe) private static var checked: (ready: Bool, at: Date)?
```

**Check:** `grep -rn 'NSLock' Sources`. Each hit becomes a `Mutex` unless a comment says why it cannot. No method called inside `withLock` takes the same `Mutex` again.

**Source:** <https://github.com/swiftlang/swift-evolution/blob/main/proposals/0433-mutex.md>; <https://developer.apple.com/documentation/synchronization/mutex>

### C6. Critical sections are short and in memory

**Level:** must

**Rule:** Under a lock, only read, copy or change in-memory values. Do no file I/O, encoding, logging, process launches or calls into other objects. Take a snapshot under the lock and do the slow work on the queue that owns writes, enqueueing it while still holding the lock so that writes stay in order.

**Why:** A lock is safe only around a tight, well-known critical section. If the hub wrote `tokens.json` or `state.json` under its lock, the listener, every phone queue and the simulator watcher would wait on the disk, and so would the menu bar panel. So the hub takes a snapshot under the lock and its writer queue writes the file. If the write is enqueued after the lock is released, two threads can enqueue their snapshots in the wrong order and leave the older one on disk.

```swift
// Do
func token(device: String, bundleID: String) -> String {
    state.withLock { state in
        let key = "\(device)|\(bundleID)"
        if let token = state.tokens[key] { return token }
        let token = Self.newToken()
        state.tokens[key] = token
        let snapshot = state.tokens
        writer.async { self.saveTokens(snapshot) }  // Cheap to enqueue; keeps writes in order.
        return token
    }
}

// Don't
lock.withLock {
    tokens[key] = token
    try? encoder.encode(tokens).write(to: paths.tokens, options: .atomic)  // Disk I/O under the lock.
}
```

**Check:** Read every `withLock` closure. Any `write(to:)`, `encode`, `Data(contentsOf:)`, `FileManager`, `FileHandle`, `log(`, `Process` or call to another type inside one is a finding. Main-actor code never takes a lock that a disk-writing path also holds.

**Source:** <https://developer.apple.com/videos/play/wwdc2021/10254/>; <https://developer.apple.com/videos/play/wwdc2022/110350/>

### C7. Global and static mutable state is isolated

**Level:** must

**Rule:** Make every global or static mutable variable a `let`, `@MainActor`, or a `Mutex`, and use `nonisolated(unsafe)` only when a named lock or queue guards every access, with that guard written on the declaration.

**Why:** Swift 6 rejects unprotected global mutable state. `nonisolated(unsafe)` turns the check off and is meant as a last resort. A value written only by `.redline()` (main actor, through `View`) and read only by `DebugSession` (`@MainActor`) belongs on the main actor.

```swift
// Do
@MainActor
enum BuildIdentity {
    /// Written by `.redline()` and read by DebugSession, both on the main actor.
    static var sourceFile: String?
}

// Don't
enum BuildIdentity {
    nonisolated(unsafe) static var sourceFile: String?
}
```

**Check:** `grep -rn 'nonisolated(unsafe)\|static var' Sources`. Each mutable static is `@MainActor`, inside a `Mutex`, or names its guard. Run `swift test --sanitize=thread` after changes.

**Source:** <https://github.com/swiftlang/swift-evolution/blob/main/proposals/0412-strict-concurrency-for-global-variables.md>; <https://www.swift.org/migration/documentation/swift-6-concurrency-migration-guide/commonproblems/>; <https://github.com/airbnb/swift#prefer-immutable-statics>

### C8. Queue-confined state is asserted

**Level:** should

**Rule:** When a serial queue guards state, touch that state only on the queue, and assert it with `dispatchPrecondition(condition: .onQueue(queue))` in the private helpers that read or write it.

**Why:** Confinement that hides behind `@unchecked Sendable` is checked by nobody. `HubLink.Line` keeps its buffer in a `nonisolated(unsafe)` property, so the only thing that keeps it safe is that `takeLine()` runs on the line's queue, and the precondition checks exactly that.

```swift
// Do
func read() async -> Data? {
    let once = Once<Data?>()
    return await withCheckedContinuation { continuation in
        once.set(continuation)
        queue.async {
            if let line = self.takeLine() { once.resume(line) } else { self.receive(once) }
        }
    }
}

private func takeLine() -> Data? {
    dispatchPrecondition(condition: .onQueue(queue))
    ...
}

// Don't
func read() async -> Data? {
    if let line = takeLine() { return line }  // Touches `buffer` off `queue`.
    ...
}
```

**Check:** For each type whose `Thread safety:` comment names a queue, find every access to the guarded properties and confirm that it runs on that queue.

**Source:** <https://www.swift.org/migration/documentation/swift-6-concurrency-migration-guide/incrementaladoption/>

### C9. UI models are `@MainActor` and receive results in one step

**Level:** must

**Rule:** Make types that drive UI (`@Observable` models, image caches, UIKit and AppKit helpers) `@MainActor`, have background work return values, and apply those values in one main-actor method. Do not write back with `MainActor.run` from a detached task.

**Why:** The main actor protects the data that UI shows. `MainActor.run` should not stand in for stating isolation in the type system, and each hop to the main actor costs a context switch. `DebugSession`, `HubWindowModel`, `RecentPhotos` and `PhotoLibrary` are `@MainActor`, which is right.

```swift
// Do
func refresh() async {
    let snapshot = await Self.loadSnapshot(paths: paths, watched: watched)
    apply(snapshot)  // @MainActor, one update.
}

/// Runs off the main actor. Add @concurrent when the tools version reaches 6.2.
nonisolated static func loadSnapshot(paths: HubPaths, watched: Set<String>) async -> Snapshot { ... }

// Don't
Task.detached(priority: .userInitiated) {
    let reports = HubWindowModel.readReports(paths: paths)
    await MainActor.run { self.reports = reports.map(\.row) }
}
```

**Check:** `grep -rn 'MainActor.run' Sources` is empty. No `@Observable` property is written off the main actor, and no loop awaits the main actor once per item.

**Source:** <https://docs.swift.org/swift-book/documentation/the-swift-programming-language/concurrency/>; <https://www.swift.org/migration/documentation/swift-6-concurrency-migration-guide/incrementaladoption/>; <https://developer.apple.com/videos/play/wwdc2021/10254/>

### C10. `MainActor.assumeIsolated` only where main-thread delivery is promised

**Level:** should

**Rule:** Use `MainActor.assumeIsolated` only inside a synchronous callback whose API promises main-thread delivery, such as an observer added with `queue: .main`, with a comment naming that promise. In such callbacks, prefer it to starting a new `Task { @MainActor in }`.

**Why:** `assumeIsolated` checks at run time and stops the app when the assumption is wrong, which is better than a race. A task per callback adds a hop and lets events arrive out of order. `DebugSession`'s keyboard and screenshot observers already use it correctly.

```swift
// Do
center.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
    // queue: .main delivers on the main thread.
    MainActor.assumeIsolated { self?.offerRecentScreenshot() }
}

// Don't
timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
    Task { @MainActor in self?.refresh() }  // A new task and a hop on every tick.
}
```

**Check:** Each `assumeIsolated` sits in a callback with `queue: .main` or a documented main-thread guarantee. `grep -rn 'Task { @MainActor' Sources` inside such callbacks becomes `assumeIsolated`.

**Source:** <https://developer.apple.com/documentation/swift/mainactor/assumeisolated(_:file:line:)>; <https://developer.apple.com/videos/play/wwdc2024/10169/>

### C11. Leave the main actor by calling a nonisolated function, not `Task.detached`

**Level:** must

**Rule:** To move work off the main actor, call a `nonisolated async` function, and use `Task.detached` only for work that must outlive and ignore its caller, with a comment saying why.

**Why:** In the Swift 6 language mode, a nonisolated async function runs off the caller's actor (SE-0338) and stays part of the caller's task, so it inherits priority, task-local values and cancellation. A detached task inherits none of these. For example, a thumbnail loaded through `await Task.detached { ... }.value` inside `.task(id:)` keeps loading after SwiftUI cancels the view's task. The 2022 advice to offload work with detached tasks is out of date.

```swift
// Do
.task(id: url) {
    guard let url else { return }
    image = await Self.load(url, pixelWidth: pointWidth * displayScale)
}

/// Decodes off the main actor, as part of the view's task. Add @concurrent at tools version 6.2.
nonisolated private static func load(_ url: URL, pixelWidth: CGFloat) async -> UIImage? { ... }

// Don't
private static func load(_ url: URL, pixelWidth: CGFloat) async -> UIImage? {
    await Task.detached(priority: .userInitiated) { ... }.value  // Not cancelled with the view.
}
```

**Check:** `grep -rn 'Task.detached' Sources`. Each hit becomes a nonisolated async call, or carries a comment saying why it must outlive its caller.

**Source:** <https://developer.apple.com/documentation/swift/task/detached(name:priority:operation:)-795w1>; <https://github.com/swiftlang/swift-evolution/blob/main/proposals/0338-clarify-execution-non-actor-async.md>

### C12. Mark off-main functions for SE-0461

**Level:** should

**Rule:** Give each nonisolated async function that must run off the main actor the comment `Runs off the main actor. Add @concurrent when the tools version reaches 6.2.`, and add `@concurrent` to all of them in the change that raises the tools version or enables `NonisolatedNonsendingByDefault`.

**Why:** Under SE-0461, nonisolated async functions run on the caller's actor, and only `@concurrent` functions leave it. Without the markers, turning the feature on would quietly move image decoding and report reading onto the main thread. Writing `@concurrent` now would break users on Swift 6.0 and 6.1 (T5). A host app's own setting does not change how this package compiles.

```swift
// Do
/// Runs off the main actor. Add @concurrent when the tools version reaches 6.2.
nonisolated static func readReports(paths: HubPaths) async -> [Report] { ... }

// Don't
@concurrent static func readReports(paths: HubPaths) async -> [Report] { ... }  // Does not compile before Swift 6.2.
```

**Check:** `grep -rn 'nonisolated.*async' Sources`. Each one that does CPU or I/O work has the comment. A `Package.swift` change that raises the tools version or adds the feature also adds `@concurrent` to every marked function.

**Source:** <https://github.com/swiftlang/swift-evolution/blob/main/proposals/0461-async-function-isolation.md>; <https://developer.apple.com/videos/play/wwdc2025/268/>

### C13. Fan out with a task group

**Level:** must

**Rule:** Run parallel work with `withTaskGroup`, not with an array of `Task { }` values, collect results by index when order matters, and limit how many child tasks run at once when the input has no fixed size.

**Why:** Child tasks are cancelled with their parent and cannot outlive the scope. Unstructured tasks keep running after the caller is cancelled. Adding thousands of child tasks at once allocates memory for each one. `AttachmentPicker.images(from:)` already does this correctly.

```swift
// Do
await withTaskGroup(of: (Int, UIImage?).self) { group in
    for (index, asset) in assets.enumerated() {
        group.addTask { (index, await PhotoLibrary.image(for: asset, pixels: PhotoLibrary.maxPixels)) }
    }
    var images = [UIImage?](repeating: nil, count: assets.count)
    for await (index, image) in group {
        images[index] = image
    }
    return images.compactMap { $0 }
}

// Don't
let requests = assets.map { asset in
    Task { await PhotoLibrary.image(for: asset, pixels: PhotoLibrary.maxPixels) }
}
```

**Check:** Search for `map` or `for` loops that create `Task { }` and then await `.value`. Each one becomes a task group. Inputs with no fixed limit keep 4 to 8 tasks in flight.

**Source:** <https://github.com/swiftlang/swift-evolution/blob/main/proposals/0304-structured-concurrency.md>; <https://www.swift.org/migration/documentation/swift-6-concurrency-migration-guide/runtimebehavior/>

### C14. Every unstructured task has an owner

**Level:** must

**Rule:** For each `Task { }`, know what stops it: keep the handle and cancel it when the view, mode or hub it serves goes away, prefer `.task` in views, and never start a new periodic or retry task while the previous one may still run.

**Why:** Dropping a task's handle does not cancel the task. A refresh that starts a new task on every tick without cancelling the last one lets slow reads stack up and land out of order, which is why the Mac panel keeps one refresh task and cancels it when the panel closes.

```swift
// Do
private var refreshing: Task<Void, Never>?

func refresh() {
    refreshing?.cancel()
    refreshing = Task {
        let snapshot = await Self.loadSnapshot(paths: paths)
        guard !Task.isCancelled else { return }
        apply(snapshot)
    }
}

// Don't
listener.newConnectionHandler = { connection in
    Task { await self.serve(Lines(connection: connection)) }  // Nothing cancels these on stop().
}
```

**Check:** For each `Task {` and `Task.detached`, name what stops it. Long-lived or repeating work has a stored handle that teardown cancels, or runs in `.task`.

**Source:** <https://developer.apple.com/documentation/swift/task/detached(name:priority:operation:)-795w1>; <https://developer.apple.com/documentation/swiftui/view/task(id:name:priority:file:line:_:)>

### C15. Cancellation is a normal outcome

**Level:** must

**Rule:** After `try? await Task.sleep(for:)`, check `Task.isCancelled` (or state that cancellation would have changed) before acting, and check for cancellation between items in long loops.

**Why:** `Task.sleep` throws `CancellationError` when the task is cancelled, and `try?` turns that into an immediate return, so a delayed action runs at once instead of never. Cancellation in Swift is cooperative: nothing stops unless code checks. `OverlayView`'s hold timer does this correctly.

```swift
// Do
hold = Task {
    try? await Task.sleep(for: .seconds(ButtonPress.holdDuration))
    guard !Task.isCancelled, press?.isDragging == false else { return }
    ...
}

// Don't
Task {
    try? await Task.sleep(for: .seconds(1))
    offerRecentScreenshot()  // Runs immediately if the task was cancelled.
}
```

**Check:** `grep -rn -A1 'try? await Task.sleep' Sources Tests`. The next line checks cancellation or re-reads state. Use `sleep(for:)`, not `sleep(nanoseconds:)`.

**Source:** <https://developer.apple.com/documentation/swift/task/sleep(for:tolerance:clock:)>; <https://docs.swift.org/swift-book/documentation/the-swift-programming-language/concurrency/>

### C16. Continuations resume exactly once and honor cancellation

**Level:** must

**Rule:** Bridge callbacks with `withCheckedContinuation` or `withCheckedThrowingContinuation`, resume exactly once on every path, including errors, timeouts and callbacks that never fire, send racing callbacks through one resume-once guard, and wrap long waits in `withTaskCancellationHandler` so cancelling the task cancels the underlying work.

**Why:** Resuming twice crashes, and never resuming leaks the task. `HubLink.Line` and `HubListener.Lines` send racing callbacks through a resume-once guard and cancel the connection when their task is cancelled. Without the cancellation handler, a cancelled send would hold the connection for up to 60 seconds.

```swift
// Do
func open(patience: TimeInterval) async -> Bool {
    let once = Once<Bool>()
    return await withTaskCancellationHandler {
        await withCheckedContinuation { continuation in
            once.set(continuation)
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready: once.resume(true)
                case .failed, .cancelled: once.resume(false)
                case .setup, .preparing, .waiting: break  // Keep waiting until patience runs out.
                @unknown default: break
                }
            }
            connection.start(queue: queue)
            queue.asyncAfter(deadline: .now() + patience) { once.resume(false) }
        }
    } onCancel: {
        connection.cancel()  // Leads to .cancelled, which resumes once.
    }
}

// Don't
await withCheckedContinuation { continuation in
    connection.stateUpdateHandler = { state in
        if case .ready = state { continuation.resume(returning: true) }
        // .failed never resumes: the task leaks.
    }
    connection.start(queue: queue)
}
```

**Check:** For each continuation, list every way out of the callback and confirm one resume on each. Long waits have a cancellation handler. `grep -rn 'withUnsafe.*Continuation' Sources` is empty.

**Source:** <https://developer.apple.com/documentation/swift/checkedcontinuation>; <https://github.com/swiftlang/swift-evolution/blob/main/proposals/0300-continuation.md>; <https://developer.apple.com/videos/play/wwdc2022/110350/>

### C17. Decode untyped data into Sendable types at the edge

**Level:** should

**Rule:** Decode untyped JSON (`[String: Any]`) into Codable, Sendable structs where it enters the program instead of wrapping it in an `@unchecked Sendable` box, and rely on region-based isolation for values created once and handed off.

**Why:** A box like `MCPServer.Request` turns off checking for everything inside it. Typed messages also remove the `as?` casts spread through the request handler. Since SE-0414 and SE-0430, the compiler can prove that a newly created value is safe to hand to a task or a continuation. The phone side already works this way: every `HubLink` message is a Codable, Sendable struct.

```swift
// Do
struct RPCRequest: Decodable, Sendable {
    enum ID: Decodable, Sendable, Hashable {
        case number(Int)
        case string(String)
    }

    let id: ID?
    let method: String
    let params: Params?
}

// Don't
private struct Request: @unchecked Sendable {
    let message: [String: Any]
}
```

**Check:** `grep -rn 'struct .*: @unchecked Sendable' Sources`. Each box has a stated reason it cannot be a typed value.

**Source:** <https://github.com/swiftlang/swift-evolution/blob/main/proposals/0414-region-based-isolation.md>; <https://github.com/swiftlang/swift-evolution/blob/main/proposals/0430-transferring-parameters-and-results.md>

### C18. Re-check state after every `await`

**Level:** must

**Rule:** In main-actor and actor code, re-read any state you read before an `await` before acting on it, and keep each read, decide and write sequence synchronous.

**Why:** Actors do not keep state unchanged across a suspension point. The result is a logic race even though no memory is corrupted. `DebugSession` mostly follows this: after awaiting the chat list, it checks that the mode is still `.destination`.

```swift
// Do
Task {
    let list = await HubLink.chats(bundleID: bundleID, address: address, sourceFile: sourceFile, patience: patience)
    guard mode == .destination else { return }  // The user may have left meanwhile.
    chatList = list.map { .loaded($0) } ?? .unavailable
}

// Don't
Task {
    let images = await loading.value
    pending?.images = images  // The user may have cancelled or started another attachment.
}
```

**Check:** In each async `@MainActor` method or task in `DebugSession` and `HubWindowModel`, find every `await`. If the code after it uses `mode`, `pending`, `suggestion`, `selection` or a captured ID, a guard re-reads it.

**Source:** <https://www.swift.org/migration/documentation/swift-6-concurrency-migration-guide/dataracesafety/>; <https://developer.apple.com/videos/play/wwdc2022/110351/>

---

## U. SwiftUI

### U1. `body` is pure and cheap

**Level:** must

**Rule:** A `body`, and every property or function it reads, does no file I/O, decoding, image work or formatter creation, writes no global or model state, and computes each derived collection at most once per evaluation.

**Why:** `body` runs on the main thread, often, inside the host app. A computed property that `body` reads belongs to that `body`'s cost (E7). That is why `DebugSession` keeps the hub's address in a stored property instead of decoding `hub.json` whenever `canPickDestination` is read, and why `NoteViewer` builds its pages once per `body`.

```swift
// Do
private(set) var canPickDestination = false  // Set at install and whenever hub.json is written.

var body: some View {
    let pages = Page.all(in: session.annotations)  // Once.
    let shown = pages.firstIndex { $0.id == shownID } ?? 0
    pager(pages, shown: shown)
}

// Don't
var canPickDestination: Bool { store.hubAddress() != nil }  // Disk read and decode, used in body.
private var pages: [Page] { annotations.enumerated().flatMap { ... } }  // Read four times per body.
```

**Check:** Follow every property and function that `body` uses back to its definition. Any path to `FileManager`, `Data(contentsOf:)`, `JSONDecoder`, `UIImage(contentsOfFile:)`, `CGImageSource`, `Process`, a `Formatter()` or a write to a static or model property is a finding. Each `filter`, `sorted`, `flatMap` or `firstIndex` over model data appears at most once per `body`, bound to a local `let`.

**Source:** <https://developer.apple.com/videos/play/wwdc2023/10160/>; <https://developer.apple.com/videos/play/wwdc2024/10150/>

### U2. Read fast-changing values only in small views

**Level:** must

**Rule:** Read a value that changes every frame (drag position, geometry, keyboard frame) only inside a small dedicated `View` struct, never in a large view's `body` or its helper properties and functions.

**Why:** SwiftUI re-runs every `body` that read an observed property when it changes. Helper properties such as `private var island: some View` are part of the parent's `body`, so only a separate `View` struct narrows the dependency. The floating button is still drawn from the root `OverlayView` `body`, so anything it reads while dragging invalidates the whole overlay. Moving it into its own view is the fix this rule asks for.

```swift
// Do
struct FloatingButton: View {
    let session: DebugSession
    @GestureState private var drag = CGSize.zero

    var body: some View {
        let center = session.buttonCenter ?? .zero  // Only this view depends on it.
        ButtonFace(count: session.annotations.count)
            .position(x: center.x + drag.width, y: center.y + drag.height)
            .gesture(dragGesture)
    }
}

// Don't
// Inside OverlayView.body, the root of the overlay:
if let center = session.buttonCenter {
    floatingButton(at: center)  // Helper function: the drag invalidates all of OverlayView.
}
```

**Check:** For each property written from a gesture's `onChanged`, `onGeometryChange`, a keyboard notification or a timer, find its readers: each is a small `View` struct. To confirm, add `let _ = Self._printChanges()` to the large view temporarily and drag on a device. It must not print once per frame.

**Source:** <https://developer.apple.com/videos/play/wwdc2023/10160/>; <https://developer.apple.com/videos/play/wwdc2023/10149/>

### U3. Choose the property wrapper by ownership

**Level:** should

**Rule:** Use `@State private` for values and models the view owns, a plain `let` for an `@Observable` model passed in, `@Bindable` only when the view uses `$model.property`, and `@Environment(Type.self)` for shared models, and use no `ObservableObject`, `@Published`, `@StateObject`, `@ObservedObject` or `@EnvironmentObject` in new code.

**Why:** This is Apple's decision flow for Observation. One convention across the package makes ownership clear at a glance.

```swift
// Do
struct DestinationPicker: View {
    let session: DebugSession  // Reads only.
}

struct OverlayView: View {
    @Bindable var session: DebugSession  // Uses $session.noteText.
}

// Don't
struct NoteViewer: View {
    @Bindable var session: DebugSession  // No $session anywhere in the file.
}
```

**Check:** Every `@Bindable` has a `$name.` use in the same file. `grep -rnE 'ObservableObject|@Published|@StateObject|@ObservedObject|@EnvironmentObject' Sources` is empty. Every `@State` is `private`.

**Source:** <https://developer.apple.com/documentation/swiftui/migrating-from-the-observable-object-protocol-to-the-observable-macro>; <https://developer.apple.com/documentation/swiftui/bindable>

### U4. `@State` defaults and view initializers are cheap

**Level:** must

**Rule:** Keep the default values of `@State` properties and the bodies of custom `View` initializers free of side effects and expensive work, and create expensive models in `.task`.

**Why:** With the `@State` property wrapper, SwiftUI builds the default value every time it creates the view value, and throws away all but the first. The newer `State()` macro creates it only once, but it needs Xcode 27 or later, and this package supports Xcode 16. That is why `AttachmentPicker` creates its `RecentPhotos`, which reads `UserDefaults`, in `.task` instead of as a default value.

```swift
// Do
@State private var library: RecentPhotos?

var body: some View {
    grid(library)
        .task {
            let library = RecentPhotos()  // Created once, when the view appears.
            self.library = library
            await library.load()
        }
}

// Don't
@State private var library = RecentPhotos()  // init reads UserDefaults on every parent update.
```

**Check:** Open every type used as an `@State` default and every custom `View` init. None does file, `UserDefaults`, Photos, network or process work, or creates a `Task`.

**Source:** <https://developer.apple.com/documentation/swiftui/state>; <https://developer.apple.com/documentation/swiftui/state()>

### U5. Do not publish unchanged values

**Level:** should

**Rule:** In refresh, poll and watcher code, compare before assigning to an `@Observable` property.

**Why:** Before Swift 6.2, the `@Observable` setter notifies on every assignment. Swift 6.2 skips only a direct assignment of an equal `Equatable` value. This package builds with Swift 6.0, and mutations in place always notify. The Mac panel refreshes every two seconds while it is open, so without a guard every row would re-render even when nothing changed.

```swift
// Do
let newReports = found.map(\.row)
if newReports != reports { reports = newReports }

// Don't
reports = found.map(\.row)  // Every tick, even when nothing changed.
```

**Check:** Every write to an `@Observable` property from a timer, poll, file watcher or notification has an equality guard, or a comment saying why the value always changes.

**Source:** <https://github.com/swiftlang/swift/pull/78151>; <https://forums.swift.org/t/observation-optimizes-away-unnecessary-callbacks-for-equatable-properties-sometimes/89358>

### U6. Format with FormatStyle, never with a new Formatter in `body`

**Level:** should

**Rule:** Format values with `FormatStyle` and `Text(_:format:)`, and show relative times that must stay current with the system's live formats, not with a string built once.

**Why:** Creating formatters in code that `body` reads was the main cause of slow view updates in Apple's 2025 performance session. A string built with `.formatted(.relative(...))` stays frozen until something else re-runs `body`. `SystemFormatStyle` (iOS 18, macOS 15) updates the text on its own schedule without re-running `body`.

```swift
// Do
Text("\(chat.folder) · \(Text(.currentDate, format: .reference(to: chat.lastActive)))")
Text(report.createdAt, format: .dateTime.day().month(.abbreviated).hour().minute())

// Don't
let ago = RelativeDateTimeFormatter().localizedString(for: chat.lastActive, relativeTo: .now)
Text("\(chat.folder) · \(ago)")
```

**Check:** `grep -rnE '(Date|Number|RelativeDateTime|Measurement|ByteCount)Formatter\(\)' Sources` finds nothing reachable from `body`. Relative dates in long-lived UI use `.reference(to:)` or `Text(date, style: .relative)`.

**Source:** <https://developer.apple.com/videos/play/wwdc2025/306/>; <https://developer.apple.com/documentation/swiftui/systemformatstyle>

### U7. Tie async work to the view's lifetime with `.task`

**Level:** must

**Rule:** Start view-related async work, including refresh loops, with `.task` or `.task(id:)`, not with `onAppear` plus a `Task` or a `Timer`, and remember that the closure starts on the main actor.

**Why:** SwiftUI cancels a `.task` when the view goes away, and restarts `.task(id:)` when the ID changes. A `Timer` in `onAppear` needs a matching `onDisappear`. `View` is `@MainActor`, so synchronous work in a `.task` closure runs on the main thread until its first `await`. Move that work behind a nonisolated function (C11).

```swift
// Do
.task {
    while !Task.isCancelled {
        await model.refresh()  // File and process work runs off the main actor.
        try? await Task.sleep(for: .seconds(2), tolerance: .milliseconds(500))
    }
}

// Don't
.onAppear { model.panelOpened() }  // Timer.scheduledTimer + Task { @MainActor in ... }
.onDisappear { model.panelClosed() }
.onAppear { Task { reports = await load() } }
```

**Check:** `grep -rn -A2 'onAppear' Sources` finds no `Task` or `Timer` created there. For the menu bar panel, confirm with a log line on macOS 15 that the loop stops when the panel closes. P1 asks whether the loop should exist at all.

**Source:** <https://developer.apple.com/documentation/swiftui/view/task(id:name:priority:file:line:_:)>; <https://developer.apple.com/documentation/swiftui/view/task(name:priority:file:line:_:)>

### U8. Start with eager stacks, go lazy for unbounded lists

**Level:** should

**Rule:** Use `VStack` or `HStack` for lists with a small fixed limit, written in the code, and a lazy stack for lists that can grow without limit.

**Why:** Apple's advice is to start with a standard stack and switch to a lazy one when profiling shows a gain. Lazy stacks give up some layout accuracy, so measuring their content height is unreliable. `SentReportsView` is right to be lazy, because history grows and each row loads an image. The Mac panel's eager stack is fine because it is capped at 30 reports.

```swift
// Do
ScrollView {
    LazyVStack(spacing: 0) {
        ForEach(reports) { ReportRow(report: $0) }  // History grows over time.
    }
}

// Don't
ScrollView {
    VStack {
        ForEach(allSentReports) { ReportRow(report: $0) }  // No limit; every row loads an image at once.
    }
}
```

**Check:** For each `ScrollView` with a `ForEach`: if the data has no small fixed limit, the stack is lazy. If it is eager, the limit appears in code. No `onGeometryChange` measures a lazy stack's content height.

**Source:** <https://developer.apple.com/documentation/swiftui/creating-performant-scrollable-stacks>

### U9. `ForEach` identity is stable, unique and stored

**Level:** must

**Rule:** Give `ForEach` IDs that survive inserts, deletes and reorders, are unique and are stored rather than computed, and inside `List` or `Table` make each element produce exactly one view.

**Why:** IDs that move lose view state and break animations, and duplicate IDs break updates. A computed string ID is rebuilt on every access by `ForEach`, `scrollPosition` and every lookup, which is why `NoteViewer.Page` stores a small `ID` struct.

```swift
// Do
struct Page: Identifiable {
    struct ID: Hashable {
        let annotation: UUID
        let index: Int
    }

    let id: ID
}

ForEach(Array(items.enumerated()), id: \.element.id) { index, item in Row(number: index + 1, item: item) }

// Don't
var id: String { "\(annotation.id.uuidString)-\(index)" }  // A new string on every access.
ForEach(Array(items.enumerated()), id: \.offset) { ... }  // Identity shifts with each deletion.
```

**Check:** No `id: \.offset`. `id: \.self` only on values known to be unique. No `UUID()` created in an `init` or `body`. Each `Identifiable.id` is a stored property.

**Source:** <https://developer.apple.com/videos/play/wwdc2021/10022/>; <https://developer.apple.com/videos/play/wwdc2023/10160/>

### U10. Preserve structural identity

**Level:** should

**Rule:** When one view changes only modifier values, use inert modifiers with conditional values instead of `if`/`else`, never use `AnyView`, and use `.id()` only to reset state on purpose.

**Why:** A branch creates two identities, and state is replaced when identity changes. `AnyView` hides type information and can make updates slower. `DeviceRowView` uses `.opacity(device.isActive ? 1 : 0.5)`, which is the pattern to follow.

```swift
// Do
Image(uiImage: image)
    .resizable()
    .aspectRatio(contentMode: fits ? .fit : .fill)

// Don't
if fits { Image(uiImage: image).resizable().scaledToFit() } else { Image(uiImage: image).resizable().scaledToFill() }
func makeRow() -> AnyView { AnyView(row) }
```

**Check:** In each `if`/`switch` inside a view builder, two branches that build the same view type with different modifier values are collapsed. `grep -rn 'AnyView' Sources` is empty. Each `.id(` is a scroll target or has a comment saying it resets state on purpose.

**Source:** <https://developer.apple.com/videos/play/wwdc2021/10022/>

### U11. Measure geometry narrowly, and only when layout cannot do it

**Level:** should

**Rule:** Solve layout with layout tools first (`containerRelativeFrame`, `ViewThatFits`, `fixedSize`), and when you must measure, use `onGeometryChange` with the narrowest `Equatable` value and write the result to local `@State`, an `@ObservationIgnored` property or a UIKit sink, never to an observed model property that large views read and never to the environment.

**Why:** Geometry can change on every frame. Writing it into observed model state re-renders everything that reads the model. The Mac report viewer keeps one `GeometryReader`, with a comment, because `containerRelativeFrame` shrank its snapshots inside a horizontal scroll view. `attachAnchor` and `attachmentSlot` are still observed `DebugSession` properties written from `onGeometryChange`, which this rule asks to change.

```swift
// Do
.onGeometryChange(for: CGFloat.self) {
    $0.size.height
} action: {
    islandHeight = $0  // Local @State.
}

// Don't
.onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { session.attachAnchor = $0 }  // Observed.
.environment(\.listHeight, height)
```

**Check:** `grep -rn 'GeometryReader' Sources`: each use has a justification. Each `onGeometryChange` transform returns the narrowest value needed, and its action writes to local state or an unobserved sink. One shared pattern exists for "a scroll view as tall as its content, up to a maximum".

**Source:** <https://developer.apple.com/documentation/swiftui/view/ongeometrychange(for:of:action:)>; <https://developer.apple.com/videos/play/wwdc2025/306/>; <https://developer.apple.com/documentation/observation/observationignored()>

### U12. Scope animations

**Level:** should

**Rule:** Animate with `withAnimation` where the state changes, with `.animation(_:value:)` on a leaf view, or with `.animation(_:body:)` for specific modifiers, and never put an implicit animation on a large container.

**Why:** An implicit animation on a container animates anything else that changes in the same update. Apple's own advice is to keep `animation(_:value:)` on leaves you fully control. The overlay's root `ZStack` animates on every mode change, so markers, the keyboard inset and the toast move with the mode's timing curve.

```swift
// Do
withAnimation(motion) { setMode(.tray) }
notesList.animation(motion) { $0.opacity(session.mode == .tray ? 1 : 0) }

// Don't
ZStack { /* every overlay surface */ }
    .animation(.smooth(duration: 0.25), value: session.mode)
```

**Check:** Each `.animation(_:value:)` sits on a leaf or a small subtree. There is no value-less `.animation(_:)`. Run mode changes with Slow Animations on and watch for views that animate by accident.

**Source:** <https://developer.apple.com/videos/play/wwdc2023/10156/>; <https://developer.apple.com/documentation/swiftui/view/animation(_:body:)>

### U13. Respect Reduce Motion everywhere, including model code

**Level:** must

**Rule:** Make every automatic spring, move or scale animation, including ones started from model code, fall back to a short fade when Reduce Motion is on.

**Why:** The Human Interface Guidelines ask apps to reduce automatic and peripheral motion when Reduce Motion is on. Redline's views read the setting, but `DebugSession` still starts the suggestion card's spring without checking it.

```swift
// Do
suggestionCard.transition(reduceMotion ? .opacity : .move(edge: edge).combined(with: .opacity))

let motion: Animation = UIAccessibility.isReduceMotionEnabled
    ? .easeOut(duration: 0.15)
    : .spring(duration: 0.4, bounce: 0.2)
withAnimation(motion) { self.suggestion = suggestion }

// Don't
withAnimation(.spring(duration: 0.4, bounce: 0.2)) { self.suggestion = suggestion }
```

**Check:** `grep -rnE 'withAnimation\(|\.transition\(|\.animation\(' Sources`. Each spring, move or scale reads the setting (`@Environment(\.accessibilityReduceMotion)` in views, `UIAccessibility.isReduceMotionEnabled` in models) or is a plain fade. Test on a device with Reduce Motion on.

**Source:** <https://developer.apple.com/design/human-interface-guidelines/accessibility>

### U14. Anything that acts on a tap is a Button

**Level:** must

**Rule:** Make every tappable control a `Button`, styled with `.buttonStyle(.plain)` when needed, and give a control that truly needs a custom gesture the full accessibility contract: one element, a label, the button trait and actions.

**Why:** A `Button` comes with the button trait and works with VoiceOver, Voice Control, Full Keyboard Access and macOS keyboard focus. `onTapGesture` gives none of these. The floating button is the model for the exception: it combines tap, hold and drag in one gesture, so it declares an element, a label, `.isButton`, a default action and a named action.

```swift
// Do
Button {
    NSWorkspace.shared.open(report.folder)
} label: {
    ReportRowContent(report: report)
}
.buttonStyle(.plain)
.help("Opens the report's folder")

// Don't
ReportRowContent(report: report)
    .contentShape(Rectangle())
    .onTapGesture { NSWorkspace.shared.open(report.folder) }
```

**Check:** `grep -rn 'onTapGesture' Sources`. Each hit is a backdrop that is hidden from accessibility or has an accessibility action, or it becomes a `Button`. Tab through the Mac panel with keyboard navigation on, and swipe through the overlay with VoiceOver.

**Source:** <https://developer.apple.com/documentation/swiftui/view/ontapgesture(count:perform:)>

### U15. Each list row is one accessibility element

**Level:** must

**Rule:** Combine each list row into one accessibility element, expose nested controls as custom actions, and never put the word "button" in an accessibility label.

**Why:** With `.accessibilityElement(children: .combine)`, the row reads as one stop and buttons inside it become custom actions. The button trait already tells VoiceOver that something is a button. The `SentReportsView` row is the model to follow.

```swift
// Do
noteRowContent
    .accessibilityElement(children: .combine)
    .accessibilityAction { session.openViewer(annotation) }
    .accessibilityAction(named: "Delete") { session.delete(annotation) }

// Don't
HStack { thumbnail; texts; deleteButton }
    .onTapGesture { session.openViewer(annotation) }
```

**Check:** In VoiceOver or Accessibility Inspector, each row is one stop that reads its title, note and state, with secondary actions under Actions. `grep -rni 'accessibilityLabel(.*button' Sources` is empty.

**Source:** <https://developer.apple.com/videos/play/wwdc2024/10073/>; <https://developer.apple.com/documentation/swiftui/view/accessibilitylabel(_:)>

### U16. Tap targets are at least 44 points on iOS and 28 on macOS

**Level:** should

**Rule:** Place small glyphs inside a frame of at least 44 by 44 points on iOS (28 by 28 on macOS) with `contentShape`, and register the whole frame with the overlay window's touchable regions.

**Why:** These are the default control sizes in the Human Interface Guidelines. Redline's usual pattern, a 26 to 32 point glyph inside a 44 point frame, should be the standard everywhere.

```swift
// Do
Button(action: dismiss) {
    Image(systemName: "xmark")
        .font(.caption.weight(.bold))
        .frame(width: 26, height: 26)
        .background(Mono.surface, in: Circle())
        .frame(width: 44, height: 44)
        .contentShape(Rectangle())
}

// Don't
Button(action: dismiss) {
    Image(systemName: "xmark").frame(width: 26, height: 26)  // A 26 point target.
}
```

**Check:** Run Accessibility Inspector's audit for small hit regions. The outermost frame of each button label is at least the minimum.

**Source:** <https://developer.apple.com/design/human-interface-guidelines/accessibility>

### U17. Readable text scales with Dynamic Type

**Level:** must

**Rule:** Set text people read with text styles, use fixed point sizes only for glyphs in fixed-size chrome (and give that chrome the Large Content Viewer), and never put text inside a fixed height.

**Why:** Text styles scale with the reader's setting. Fixed sizes do not, and fixed heights clip text at large sizes. `@ScaledMetric` scales spacing that sits next to text. The floating button and island are fixed chrome over the host app, so they suit a capped `dynamicTypeSize` plus the Large Content Viewer. The viewer opens on a long press, which conflicts with the floating button's own hold gesture, so check that on a device.

```swift
// Do
Text("Add \(selectedIDs.count)")
    .font(.callout.weight(.semibold))
    .padding(.horizontal, 22)
    .frame(minHeight: 44)
@ScaledMetric(relativeTo: .callout) private var gridSpacing: CGFloat = 6

// Don't
Text("All Photos")
    .font(.system(size: 16, weight: .semibold))
    .frame(height: 44)
```

**Check:** `grep -rn 'font(.system(size:' Sources`: each hit is on an SF Symbol, an image or a number badge, never on text people read. No fixed `.frame(height:)` directly around `Text`. View the overlay at the largest accessibility text size.

**Source:** <https://developer.apple.com/videos/play/wwdc2024/10074/>; <https://developer.apple.com/documentation/swiftui/view/accessibilityshowslargecontentviewer()>; <https://developer.apple.com/design/human-interface-guidelines/typography>

### U18. `UIViewRepresentable` follows its contract

**Level:** must

**Rule:** Do all one-time setup in `makeUIView`, keep `updateUIView` idempotent by comparing before assigning, refresh the coordinator's closures on every update, never set the root view's frame, bounds, center or transform, and remove observers in `dismantleUIView`.

**Why:** SwiftUI controls the layout of the wrapped view, and setting its geometry yourself is undefined behavior. `updateUIView` runs for any relevant change, so anything it creates piles up. `ZoomableSnapshot` is the reference implementation.

```swift
// Do
func updateUIView(_ view: ZoomView, context: Context) {
    context.coordinator.zoomChanged = zoomChanged  // Closures capture current state.
    context.coordinator.tapped = tapped
    if view.photo.image !== image { view.show(image) }
}

// Don't
func updateUIView(_ view: ZoomView, context: Context) {
    view.addGestureRecognizer(UITapGestureRecognizer(...))  // Piles up on every update.
    view.show(image)                                        // Reloads every time.
    view.frame = proposedFrame                              // Fights SwiftUI layout.
}
```

**Check:** `updateUIView` creates no recognizers, observers or subviews and sets no geometry on the returned view. Every notification or KVO registration has a matching removal in `dismantleUIView`.

**Source:** <https://developer.apple.com/documentation/swiftui/uiviewrepresentable>; <https://developer.apple.com/documentation/swiftui/uiviewrepresentable/dismantleuiview(_:coordinator:)>

### U19. The overlay window never takes over the host app

**Level:** must

**Rule:** Show the overlay window with `isHidden = false`, never `makeKeyAndVisible()`, let touches through by hit-testing alone, and clear every touchable region when its view disappears.

**Why:** A key window takes keyboard focus and first-responder events from the host app. Returning `nil` from `hitTest` sends the touch on to the app's windows. A touchable region that is never cleared leaves a dead zone after the view is gone. `DebugSession.install` already follows the window part. Global frames equal window coordinates only because the overlay fills the screen, so note that assumption next to the code.

```swift
// Do
let window = OverlayWindow(windowScene: scene)
window.windowLevel = .alert + 1
window.rootViewController = host
window.isHidden = false  // Visible, not key.

.onDisappear { session.setTouchableFrame(nil, for: "suggestion") }

// Don't
window.makeKeyAndVisible()  // Takes key status and keyboard focus from the host app.
```

**Check:** `grep -rn 'makeKeyAndVisible' Sources/Redline` is empty. `OverlayWindow` overrides only hit-testing and layout. Every `setTouchableFrame(frame, for:)` has a matching `setTouchableFrame(nil, for:)`. On a device, with Redline idle, taps anywhere except the button reach the host app.

**Source:** <https://developer.apple.com/documentation/uikit/uiwindow/makekeyandvisible()>; <https://developer.apple.com/documentation/uikit/uiview/hittest(_:with:)>; <https://developer.apple.com/documentation/swiftui/uihostingcontroller/safearearegions>

### U20. The menu bar panel behaves like a menu bar extra

**Level:** should

**Rule:** Use the window style only for rich content, set the panel's color scheme with `preferredColorScheme` instead of the `colorScheme` environment value, keep the accessory activation policy, and do no work while the panel is closed.

**Why:** `preferredColorScheme` reaches the presenting window, while setting `\.colorScheme` changes only the SwiftUI content, so the panel's window keeps the system appearance. An SwiftPM executable has no Info.plist, so `setActivationPolicy(.accessory)` stands in for `LSUIElement`; keep it.

```swift
// Do
MenuBarExtra {
    HubPanel(model: model)
} label: {
    Image(nsImage: MenuBarIcon.image)
}
.menuBarExtraStyle(.window)
// In HubPanel:
.preferredColorScheme(.dark)

// Don't
.environment(\.colorScheme, .dark)  // The panel window keeps the system appearance.
```

**Check:** With macOS in light mode, the panel's background and controls are dark. With the panel closed, Activity Monitor shows no CPU use and no `simctl` processes. No Dock icon appears.

**Source:** <https://developer.apple.com/documentation/swiftui/menubarextra>; <https://developer.apple.com/documentation/swiftui/view/preferredcolorscheme(_:)>; <https://developer.apple.com/design/human-interface-guidelines/the-menu-bar>

### U21. Use current API spellings

**Level:** should

**Rule:** Use the current form of each API even when the deployment target hides the deprecation warning.

**Why:** People read a public SDK with the newest SDK installed. Deprecation warnings appear only when the deployment target is at or above the deprecating version, so they stay hidden here. `Text + Text` is deprecated in iOS and macOS 26, and interpolating styled `Text` works on iOS 18 and macOS 15.

```swift
// Do
Text("\(Text(report.agent).foregroundStyle(.primary))\(Text(" · ").foregroundStyle(.secondary))\(report.chat)")

// Don't
Text(report.agent).foregroundStyle(.primary) + Text(" · ").foregroundStyle(.secondary) + Text(report.chat)
```

**Check:** `grep -rnE '\+ Text\(|\.foregroundColor\(|\.cornerRadius\(|NavigationView|onChange\(of:[^)]*perform:' Sources` is empty. Occasionally build with the deployment target raised to the newest OS and read the deprecation warnings.

**Source:** <https://developer.apple.com/documentation/swiftui/text/+(_:_:)>

---

## P. Performance

The targets: no wakeups while idle, no main-thread hang over 250 ms, flat memory across repeated actions, and no file, log or collection that grows without limit.

### P1. React to events, do not poll

**Level:** must

**Rule:** Refresh state when something reports a change (the hub, a file-system source, a notification), not on a fixed timer, and keep the iOS overlay free of timers and display links while it is idle.

**Why:** Every timer fire wakes the CPU, and Apple names polling as the thing to replace with events. While it is open, the Mac panel still re-reads the inbox and runs `xcrun simctl` every two seconds, even though the hub already learns of every change itself. The iOS overlay already reacts only to notifications.

```swift
// Do
// The hub yields from receive(), phoneChanged() and SimulatorWatcher.rescan().
HubPanel(model: model)
    .task {  // Cancelled when the panel closes.
        await model.refresh()
        for await _ in hub.changes { await model.refresh() }
    }

// Don't
timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
    Task { @MainActor in self?.refresh() }  // Re-reads the inbox and runs simctl every 2 s.
}
```

**Check:** `grep -rnE 'Timer|makeTimerSource|asyncAfter|Task\.sleep' Sources`. Each repeating one has a comment saying why no event source exists. With the panel closed, Activity Monitor's Idle Wake Ups for Redline is at or near zero.

**Source:** <https://developer.apple.com/library/archive/documentation/Performance/Conceptual/power_efficiency_guidelines_osx/Timers.html>

### P2. Timers that remain have tolerance and an owner

**Level:** should

**Rule:** Give every remaining timer a tolerance or leeway of at least 10 percent of its interval and a cancel path tied to its owner, use a `.task` loop in SwiftUI, a `DispatchSourceTimer` on the owning queue in queue code, and `NSBackgroundActivityScheduler` for maintenance that runs every 10 minutes or more.

**Why:** Tolerance lets the system group wakeups from many apps, and a `Timer`'s default tolerance is zero. Forgetting to stop timers is one of the biggest energy costs on the Mac. The scheduler picks an efficient time for work like the hub's 30-minute rediscovery, which other events already cover.

```swift
// Do
try? await Task.sleep(for: .seconds(2), tolerance: .milliseconds(500))
timer.schedule(deadline: .now(), repeating: .seconds(1800), leeway: .seconds(180))

let activity = NSBackgroundActivityScheduler(identifier: "Redline.hub.rediscover")
activity.repeats = true
activity.interval = 30 * 60
activity.tolerance = 10 * 60
activity.qualityOfService = .utility
// stop(): activity.invalidate()

// Don't
Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in refresh() }  // Tolerance 0.
timer.schedule(deadline: .now(), repeating: 1800, leeway: .seconds(60))     // About 3 percent.
```

**Check:** For each timer, divide the tolerance by the interval: less than 0.1 is a finding. Find the cancel call and confirm it runs when the owner stops. The scheduler's block calls `completion` on every path.

**Source:** <https://developer.apple.com/library/archive/documentation/Performance/Conceptual/power_efficiency_guidelines_osx/Timers.html>; <https://developer.apple.com/library/archive/documentation/Performance/Conceptual/power_efficiency_guidelines_osx/SchedulingBackgroundActivity.html>; <https://developer.apple.com/documentation/foundation/timer/tolerance>

### P3. One helper starts every child process

**Level:** must

**Rule:** Start every child process (git, devicectl, simctl, claude) through one internal helper that always has a timeout, sends SIGTERM and then SIGKILL after a short grace period, reads output while the child runs, caps captured output, and in its async form resumes from `terminationHandler`; only callers on a named serial queue or in synchronous command-line setup may use its blocking form.

**Why:** Redline still starts processes in several places, and most of them have no timeout. `devicectl` can hang on a phone that drops off Wi-Fi, and it runs on queues that also serve the hub, so one hung call stalls the hub. `waitUntilExit` polls the run loop until the child exits: on the main thread it runs other work re-entrantly, and on a cooperative thread it holds the thread (C1). Apple's DTS points to swift-subprocess as the design to follow. AGENTS.md forbids the dependency, so copy the design, not the package. One helper replacing five copies passes A10.

```swift
// Do
let output = try await Command.run(
    devicectl,
    arguments: ["list", "devices", "--json-output", file.path(percentEncoded: false), "--quiet"],
    timeout: .seconds(15),
    outputLimit: 256_000
)

// Inside Command.run (sketch):
return try await withCheckedThrowingContinuation { continuation in
    process.terminationHandler = { finished in continuation.resume(returning: collect(finished)) }
    do { try process.run() } catch {
        process.terminationHandler = nil
        continuation.resume(throwing: error)
    }
}

// Don't
try process.run()
let output = pipe.fileHandleForReading.readDataToEndOfFile()  // No deadline.
process.waitUntilExit()                                       // Polls this thread's run loop.
```

**Check:** `grep -rn 'Process()' Sources` finds only the helper. `grep -rnE 'waitUntilExit|readDataToEndOfFile' Sources` finds nothing outside it, except reading a hook's own standard input. A test runs `/bin/sleep 30` with a 1 second timeout and asserts that it returns within about 3 seconds and the child is gone.

**Source:** <https://developer.apple.com/documentation/foundation/process/waituntilexit()>; <https://developer.apple.com/documentation/foundation/process/terminationhandler>; <https://developer.apple.com/forums/thread/690310>; <https://github.com/swiftlang/swift-subprocess>

### P4. Start processes rarely

**Level:** should

**Rule:** Cache each child process's result with a stated lifetime or a stated invalidating event, and prefer data the hub already watches over asking a tool again.

**Why:** Each launch costs a fork, an exec and library loading, and `xcrun` adds a lookup before the real tool starts. The repo already does this right in two places: `Devicectl.locate` runs once and `ClaudeCLI` caches its answer for 60 seconds.

```swift
// Do
private var booted: (list: [Simulator], at: ContinuousClock.Instant)?

func bootedSimulators() async throws -> [Simulator] {
    if let booted, booted.at.duration(to: .now) < .seconds(30) { return booted.list }
    let list = try await Simctl.booted(timeout: .seconds(10))  // One launch.
    booted = (list, .now)
    return list
}
// Also cleared when SimulatorWatcher reports a change.

// Don't
func refresh() {
    let booted = HubWindowModel.fetchBootedSimulators()  // xcrun simctl on every 2 s tick.
}
```

**Check:** Each cache names what clears it. With the panel open and nothing changing, Instruments System Trace shows no short-lived `xcrun`, `simctl` or `devicectl` processes.

**Source:** <https://developer.apple.com/library/archive/documentation/Performance/Conceptual/power_efficiency_guidelines_osx/MonitoringEnergyUsage.html>

### P5. A small fixed set of serial queues

**Level:** should

**Rule:** Create one serial queue per subsystem with an explicit quality of service, and have objects that exist once per connection or per phone target their subsystem's queue instead of creating a root queue of their own.

**Why:** Apple's GCD guidance is a fixed number of serial queue hierarchies. Many independent queues that become active together cause extra threads and context switches. Quality of service sets CPU, I/O and timer priority, and background work should run at utility or lower. That is why each hub connection and each phone has a queue that targets one subsystem queue, such as `Redline.hub.network`.

```swift
// Do
static let network = DispatchQueue(label: "Redline.hub.network", qos: .utility)
private let queue = DispatchQueue(label: "Redline.hub.connection", target: HubListener.network)

// Don't
private let queue = DispatchQueue(label: "listener.connection")  // A new root queue per connection.
```

**Check:** Every `DispatchQueue(label:` is either a static subsystem queue with `qos:` or passes `target:`. Labels start with `Redline.`.

**Source:** <https://developer.apple.com/videos/play/wwdc2017/706/>; <https://developer.apple.com/library/archive/documentation/Performance/Conceptual/power_efficiency_guidelines_osx/PrioritizeWorkAtTheTaskLevel.html>

### P6. Persisted state is written on change and has a size limit

**Level:** must

**Rule:** Write a persisted file only when its content changed, combine bursts of changes into one write, and give every persisted collection, log and folder a stated size or age limit with code that enforces it.

**Why:** The hub runs for months. `hub.log` rolls over at 5 MB, and the status file is written only when a phone changes. `SourceState.delivered` still gains one ID per report and the inbox is never pruned, so every scan gets slower over time; both still need a limit.

```swift
// Do
func phoneChanged(_ phone: Devicectl.Phone, state description: String) {
    let new = HubStatus.Phone(name: phone.name, udid: phone.udid, state: description, model: phone.model)
    let changed = state.withLock { $0.phones.updateValue(new, forKey: phone.udid) != new }
    if changed { writeStatus() }
}
// Keep only delivered IDs the phone still offers. Roll hub.log at 5 MB.

// Don't
func phoneChanged(_ phone: Devicectl.Phone, state description: String) {
    lock.withLock { phoneStates[phone.udid] = HubStatus.Phone(...) }
    writeStatus()  // Writes even when nothing changed.
}
```

**Check:** List every file the hub and the kit write (`state.json`, `tokens.json`, `status.json`, `hub.log`, inbox folders, the iOS reports folder). For each, point to the guard that skips unchanged writes and to the pruning rule. A test that files 5,000 reports asserts that `state.json` stays under a fixed size.

**Source:** <https://developer.apple.com/library/archive/documentation/Performance/Conceptual/power_efficiency_guidelines_osx/MinimizingIO.html>

### P7. Do not rescan and re-decode whole folders to show a few items

**Level:** should

**Rule:** List folders with prefetched resource keys, choose the newest N before decoding anything, decode each file once into everything the caller needs, cache by URL and modification date, and pass along a path you already know instead of searching for it.

**Why:** Disk reads cost time and energy. The panel reads only the newest 30 reports in full, the handoff uses the folder it was given instead of rescanning, and the kit skips delivered reports before decoding the rest. A folder's modification date changes when a file inside it is added or atomically replaced, which is how the hub writes delivery and claim files, so the date works as a cache key.

```swift
// Do
let keys: [URLResourceKey] = [.creationDateKey, .contentModificationDateKey]
let newest = try files.contentsOfDirectory(at: appFolder, includingPropertiesForKeys: keys)
    .sorted { created($0) > created($1) }
    .prefix(30)

// Don't
for name in try files.contentsOfDirectory(atPath: appFolder.path) {  // Every report, every tick.
    let snapshots = ReportContent.snapshots(in: folder)               // Decodes report.json.
    let notes = notes(in: folder)                                     // Decodes it again.
}
```

**Check:** A performance test (T3) builds a 500-report fixture inbox and measures the panel read. With nothing changed, a refresh reads no `report.json`. Instruments File Activity shows no repeated reads of unchanged files.

**Source:** <https://developer.apple.com/library/archive/documentation/Performance/Conceptual/power_efficiency_guidelines_osx/MinimizingIO.html>

### P8. Decode images as thumbnails, off the main actor, into a bounded cache

**Level:** must

**Rule:** For display, decode images only as Image I/O thumbnails at the displayed pixel size, from a source created with `kCGImageSourceShouldCache: false`, in a nonisolated function rather than on the main actor, and keep them in an `NSCache` with a limit, never in a plain dictionary.

**Why:** A decoded bitmap costs 4 bytes per pixel whatever the file size, so a full screenshot shown in a 96 point card wastes megabytes. `kCGImageSourceShouldCacheImmediately` decodes at creation, off the main thread, instead of at first draw on it. Without a maximum pixel size, a thumbnail can be as large as the image. `NSCache` evicts under memory pressure. A plain dictionary never evicts in an app that never quits. `Thumbnails` on the Mac and `SentReportsView` and `PhotoLibrary` on iOS use the right Image I/O options.

```swift
// Do
let cache = NSCache<NSURL, NSImage>()  // countLimit = 60

/// Runs off the main actor. Add @concurrent when the tools version reaches 6.2.
nonisolated static func thumbnail(_ url: URL, maxPixels: Int) -> CGImage? {
    let options = [kCGImageSourceShouldCache: false] as CFDictionary
    guard let source = CGImageSourceCreateWithURL(url as CFURL, options) else { return nil }
    return CGImageSourceCreateThumbnailAtIndex(source, 0, [
        kCGImageSourceCreateThumbnailFromImageAlways: true,
        kCGImageSourceCreateThumbnailWithTransform: true,
        kCGImageSourceShouldCacheImmediately: true,
        kCGImageSourceThumbnailMaxPixelSize: maxPixels,
    ] as CFDictionary)
}

// Don't
@MainActor enum ThumbnailCache {
    private static var images: [URL: NSImage] = [:]  // Never evicted, decoded on the main actor.
}
Image(uiImage: suggestion.image).frame(width: 96)  // A full-resolution bitmap for a 96 point card.
```

**Check:** Each `CGImageSourceCreateThumbnailAtIndex` passes all four keys, its source has caching off, and main-actor code cannot reach it. `grep -rnE '\[URL: (NS|UI)Image\]' Sources` is empty. `UIImage(contentsOfFile:` and `NSImage(contentsOf` do not appear in views or in model methods that `body` calls. In Instruments Allocations, opening and closing the panel 50 times keeps persistent memory flat.

**Source:** <https://developer.apple.com/videos/play/wwdc2018/416/>; <https://developer.apple.com/documentation/xcode/making-changes-to-reduce-memory-use>; <https://developer.apple.com/documentation/imageio/kcgimagesourceshouldcacheimmediately>; <https://developer.apple.com/documentation/foundation/nscache>

### P9. Network input is parsed in linear time and bounded memory

**Level:** must

**Rule:** When splitting a byte stream into lines, search only the bytes that arrived since the last search, and send large binary content as length-prefixed raw bytes after a small JSON header, not as base64 inside one JSON line, versioning the protocol when you change it (A12).

**Why:** A reader that searches its whole buffer for a newline after every chunk is quadratic in the line length, and removing the line then copies the rest of the buffer. The Mac's `LineBuffer` keeps a scan offset; the kit's `HubLink.Line` still searches from the start. `JSONEncoder` encodes `Data` as base64 by default, so a 50 MB report becomes a 67 MB line that each side holds in memory more than once.

```swift
// Do
guard let newline = buffer[scanned...].firstIndex(of: UInt8(ascii: "\n")) else {
    scanned = buffer.endIndex
    return nil
}

// A JSON header line with file names and byte counts, then each file's raw bytes.
connection.receive(minimumIncompleteLength: size, maximumLength: size) { data, _, _, error in ... }

// Don't
guard let newline = buffer.firstIndex(of: UInt8(ascii: "\n")) else { return nil }  // Rescans everything.
let line = HubMessage.encode(Upload(id: id, files: store.reportFiles(id)))         // Every file, base64.
```

**Check:** `grep -rn 'firstIndex(of: UInt8(ascii: "\\n"))' Sources` hits only searches that start at a saved offset. A test sends a 40 MB upload over a loopback listener: doubling the size roughly doubles the time.

**Source:** <https://developer.apple.com/videos/play/wwdc2018/715/>; <https://developer.apple.com/documentation/foundation/jsonencoder/dataencodingstrategy-swift.property>

### P10. A timeout is cancelled when its operation finishes

**Level:** should

**Rule:** Create each timeout together with the operation it guards, as a `DispatchWorkItem` or timer, and cancel it on the success path.

**Why:** Each pending timer is a future wakeup. A 60 second timeout that is never cancelled fires long after the line arrived, and a terminate block left behind after a child process exits keeps the `Process` alive until it fires.

```swift
// Do
let timeout = DispatchWorkItem { once.resume(nil) }
queue.asyncAfter(deadline: .now() + 60, execute: timeout)
receive { line in
    timeout.cancel()
    once.resume(line)
}

// Don't
queue.asyncAfter(deadline: .now() + 60) { once.resume(nil) }  // Fires even after the line arrived.
```

**Check:** Every `asyncAfter` used as a timeout keeps a work item and cancels it. After a phone delivers a report, `timerfires` shows no Redline timer firing 30 to 60 seconds later.

**Source:** <https://developer.apple.com/library/archive/documentation/Performance/Conceptual/power_efficiency_guidelines_osx/Timers.html>

### P11. Retries are event-driven, backed off, and one at a time

**Level:** must

**Rule:** Start retries from events, back off exponentially to a cap, reset on success or when a phone wakes or the network path changes, never run two attempts at once, and let `NWConnection`'s waiting state handle missing connectivity instead of checking reachability first.

**Why:** A reachability check before connecting races with reality. `PhoneLink` is the model to copy: 30 seconds doubling to 300, reset on wake or address change. The missing piece is the one-at-a-time guard. `DebugSession.offerUndeliveredReports()` still starts a new delivery on every app activation without checking for one in progress, so quick app switches can send the same reports in parallel.

```swift
// Do
private var delivery: Task<Void, Never>?

private func offerUndeliveredReports() {
    guard delivery == nil, UserDefaults.standard.bool(forKey: Self.hubReachedKey) else { return }
    let store = store
    delivery = Task { [weak self] in
        _ = await ReportDelivery.deliver(from: store, bundleID: Bundle.main.bundleIdentifier, patience: 8)
        self?.delivery = nil
    }
}

// Don't
center.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
    Task { _ = await ReportDelivery.deliver(from: store, bundleID: bundleID, patience: 8) }  // One more per activation.
}
```

**Check:** For each retry path, name its trigger, cap, reset and in-progress guard. A test posts the activation notification five times quickly against a loopback hub and sees one connection. Any reachability gate before `connection.start()` is a finding.

**Source:** <https://developer.apple.com/videos/play/wwdc2018/715/>

### P12. Do not opt out of App Nap

**Level:** should

**Rule:** Leave App Nap on, and mark only the short user-visible stretch of filing an incoming report and handing it to a chat as a `ProcessInfo` activity, ended in a `defer` or completion.

**Why:** A menu bar app with no visible window naps, which lowers its priority and throttles timers and I/O. That is right while idle. While a report is on its way to a chat, the user is waiting, so that stretch should run as user-initiated work. Turning App Nap off in Info.plist would also add the configuration that the one-line setup avoids.

```swift
// Do
func receive(_ source: ReportSource, copy: (_ destination: URL) throws -> Void) throws {
    let activity = ProcessInfo.processInfo.beginActivity(
        options: .userInitiatedAllowingIdleSystemSleep,
        reason: "Filing a report from a device"
    )
    defer { ProcessInfo.processInfo.endActivity(activity) }
    ...
}

// Don't
// At launch, for the life of the process:
_ = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .latencyCritical], reason: "Hub")
```

**Check:** Each `beginActivity` covers one operation and ends in a `defer` or completion, and none starts at launch. When idle, Activity Monitor shows App Nap: Yes and Preventing Sleep: No.

**Source:** <https://developer.apple.com/library/archive/documentation/Performance/Conceptual/power_efficiency_guidelines_osx/AppNap.html>; <https://developer.apple.com/documentation/foundation/processinfo/activityoptions>

### P13. File watching is narrow and handles dropped events

**Level:** must

**Rule:** Watch narrow FSEvents roots with folder-level events unless file-level events are truly needed, ignore events caused by the hub's own writes, do a full rescan when an event carries `MustScanSubDirs`, and treat Dispatch file-system events as hints to re-read state, not as a count of changes.

**Why:** File-level events produce far more callbacks. The watcher ignores the event flags, so after a coalesced or dropped batch, reports are missed until the next 30-minute rescan. The hub writes `hub.json` inside folders it watches, which wakes its own stream; `kFSEventStreamCreateFlagIgnoreSelf` exists for this. Dispatch merges events that arrive while a handler is pending.

```swift
// Do
let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagIgnoreSelf)
let callback: FSEventStreamCallback = { _, info, count, paths, eventFlags, _ in
    guard let info else { return }
    let watcher = Unmanaged<SimulatorWatcher>.fromOpaque(info).takeUnretainedValue()
    let mustRescan = (0..<count).contains {
        eventFlags[$0] & FSEventStreamEventFlags(kFSEventStreamEventFlagMustScanSubDirs) != 0
    }
    if mustRescan { watcher.takeAllNewReports() } else { watcher.filesDidChange(at: ...) }
}

// Don't
let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes)
let callback: FSEventStreamCallback = { _, info, count, paths, _, _ in ... }  // Flags ignored.
```

**Check:** The callback reads `eventFlags`. A test feeds it a `MustScanSubDirs` event and checks that every watched container is rescanned. Every Dispatch file-system handler re-derives state from disk.

**Source:** <https://developer.apple.com/documentation/coreservices/kfseventstreamcreateflagfileevents>; <https://developer.apple.com/documentation/coreservices/kfseventstreamcreateflagignoreself>; <https://developer.apple.com/documentation/coreservices/kfseventstreameventflagmustscansubdirs>

### P14. One configured coder per format, Codable for known schemas

**Level:** should

**Rule:** Keep one configured `JSONEncoder` and `JSONDecoder` per format in each module as static constants, use Codable rather than `JSONSerialization` for any schema you know, decode each file once into a narrow struct with every field the caller needs, and pretty-print only files people read.

**Why:** Foundation's JSON coders are now native Swift implementations and much faster than going through `JSONSerialization` and `Any` casts. Creating and configuring a coder on every call is wasted work, and three different structs for the same file mean three decodes. `HubPaths.encoder`, `HubPaths.decoder` and the coders in `HubLink` and `ReportStore` follow this rule.

```swift
// Do
struct SimctlDevices: Decodable {
    struct Device: Decodable {
        var udid: String
        var name: String
    }

    var devices: [String: [Device]]
}
let booted = try HubPaths.decoder.decode(SimctlDevices.self, from: output.data)

// Don't
let encoder = JSONEncoder()  // A new encoder on every status write.
encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }
```

**Check:** `grep -rnE 'JSON(En|De)coder\(\)' Sources` finds only static initializers. `JSONSerialization` appears only for open-ended data such as MCP parameters. Machine-only files that are written often do not use `.prettyPrinted`.

**Source:** <https://www.swift.org/blog/foundation-preview-now-available/>

### P15. Performance claims come with device numbers

**Level:** should

**Rule:** Measure before and after any change to timers, file watching, process launches, images, the wire protocol or a hot SwiftUI view, on real hardware, and put the numbers in the pull request.

**Why:** Apple's guidance is never to profile in the simulator, and AGENTS.md says a simulator run does not prove device behavior. Apple suggests investigating if an idle app wakes more than once per second. Its tools flag hangs at 250 ms, and people notice delays from about 100 ms. Most costs in this package show up only with a real-sized inbox.

```swift
// Do
var body: some View {
    #if DEBUG
    let _ = Self._printChanges()  // Temporary, while reviewing. Removed before commit.
    #endif
    content
}
// PR text: "Idle wakeups with panel closed: 0.4/s before, 0.0/s after (Activity Monitor, 5 min)."

// Don't
// Committed: let _ = Self._printChanges()
// PR text: "Faster now, checked in the simulator."
```

**Check:** Pull requests in these areas state numbers from Activity Monitor (Idle Wake Ups, panel closed, 5 minutes), Instruments (Hangs, Time Profiler, Allocations, the SwiftUI instrument) or the T3 tests. `grep -rn '_printChanges' Sources` is empty.

**Source:** <https://developer.apple.com/documentation/swiftui/creating-performant-scrollable-stacks>; <https://developer.apple.com/videos/play/wwdc2025/306/>; <https://developer.apple.com/library/archive/documentation/Performance/Conceptual/power_efficiency_guidelines_osx/MonitoringEnergyUsage.html>; <https://developer.apple.com/documentation/xcode/understanding-hangs-in-your-app>

---

## E. Swift idioms and error handling

### E1. Choose how a function reports failure on purpose

**Level:** must

**Rule:** Return an optional only when "no value" is the only way to fail, use untyped `throws` when callers need the reason or must not miss the failure, use typed throws only for a fixed set of internal errors the module handles itself, use `Result` only to store or pass an outcome, and never return a success `Bool` marked `@discardableResult`.

**Why:** The Swift book says most code should not specify an error type, and SE-0413 warns against typed throws just because an implementation throws one type today. async/await covers most past uses of `Result`. `HubLink.requestChats` still returns nil both when the hub is unreachable and when it refuses, two cases the picker could explain differently. `Hub.receive` throws, so no caller can drop the only sign that a report was not filed, and `HubLink.deliver` returns a clear `Outcome` enum.

```swift
// Do
enum HubLinkError: Error {
    case unreachable
    case refused(reason: String)
}

/// The chats a report from this app can go to.
/// - Throws: `HubLinkError.unreachable` when no host answers, or
///   `HubLinkError.refused` when the hub turns the request down.
static func requestChats(
    bundleID: String,
    address: Address,
    sourceFile: String?,
    patience: TimeInterval
) async throws(HubLinkError) -> ChatList

// Don't
/// Nil when the hub can't be reached or turns the question down.
static func requestChats(...) async -> ChatList?

@discardableResult
func receive(_ source: ReportSource, copy: (URL) -> Bool) -> Bool
```

**Check:** These are findings: an optional or `Bool` return whose doc gives two or more reasons for nil or false; `@discardableResult` on a function whose result is its only sign of failure; `throws(SomeError)` on a public declaration; a `Result` return that could be `async throws`.

**Source:** <https://docs.swift.org/swift-book/documentation/the-swift-programming-language/errorhandling/#Specifying-the-Error-Type>; <https://github.com/swiftlang/swift-evolution/blob/main/proposals/0413-typed-throws.md>; <https://github.com/swiftlang/swift-evolution/blob/main/proposals/0235-add-result.md>

### E2. `try?` only where failure really means "nothing there"

**Level:** must

**Rule:** Use `try?` only for best-effort cleanup or for a probe whose failure is handled exactly like absence and is never followed by a write to the same place, never to drop a failed write without a log line, and never so that a decode failure looks like a missing file.

**Why:** `try?` treats every error the same way. If `loadDraft()` turned an `annotations.json` it cannot decode into `[]`, the next save would overwrite the user's notes; it throws instead, and the session sets the file aside. A dropped state write would let reports be delivered twice after a restart with no trace, and a changed `devicectl` JSON format would look like an unplugged phone. `try? await Task.sleep` also swallows cancellation (C15).

```swift
// Do
func loadDraft() throws -> [Annotation] {
    let data: Data
    do {
        data = try Data(contentsOf: draftFile)
    } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
        return []  // No draft yet.
    }
    return try Self.decoder.decode([Annotation].self, from: data)
}

// The caller logs the error and sets the unreadable file aside instead of overwriting it.

// Don't
func loadDraft() -> [Annotation] {
    guard let data = try? Data(contentsOf: draftFile) else { return [] }
    return (try? Self.decoder.decode([Annotation].self, from: data)) ?? []
}

try? encoder.encode(state).write(to: paths.state, options: .atomic)
```

**Check:** `grep -rn 'try?' Sources`. Each is cleanup, an absence probe never followed by a write to the same place, or has a short comment saying why failure is fine. Any `try? ... write(` or `try? encoder.encode` without a log line is a finding.

**Source:** <https://docs.swift.org/swift-book/documentation/the-swift-programming-language/errorhandling/#Converting-Errors-to-Optional-Values>

### E3. No force unwrap after a check; no `try!` or `as!`

**Level:** must

**Rule:** Carry an unwrapped value forward with `if let`, `guard let`, `compactMap` or `dictionary[key, default:]` instead of force unwrapping something you just checked, keep `!` for true programmer errors with a comment saying why nil is impossible, and use no `try!` or `as!` in `Sources`.

**Why:** `!` is a short spelling of a crash. Code that checks and then forces works until someone edits the check, and every reader has to prove it safe again. A crash in Redline is a crash in someone else's app.

```swift
// Do
let scrolled = captures
    .compactMap { capture in capture.scroll.map { (capture: capture, scroll: $0) } }
    .sorted { $0.scroll.offsetY < $1.scroll.offsetY }

if let label = element.label, label != item.title {
    details.append("label \"\(label)\"")
}

// Don't
let scrolled = captures.filter { $0.scroll != nil }
    .sorted { $0.scroll!.offsetY < $1.scroll!.offsetY }

if element.label != nil, element.label != item.title {
    details.append("label \"\(element.label!)\"")
}
```

**Check:** Turn on swift-format `NeverForceUnwrap` and `NeverUseForceTry`. `grep -rnE 'try!|as! ' Sources` is empty. Every remaining `!` has a comment.

**Source:** <https://docs.swift.org/swift-book/documentation/the-swift-programming-language/thebasics/#Force-Unwrapping>; <https://github.com/swiftlang/swift-format/blob/main/Documentation/RuleDocumentation.md>

### E4. Exhaustive switches over your own enums

**Level:** must

**Rule:** Switch over enums declared in this package without `default:`, so a new case is a compile error at every switch, and for enums from Apple frameworks, list the cases you ignore and end with `@unknown default`.

**Why:** A `default` case stops the compiler from telling you that a new case is not handled, and `@unknown default` keeps that warning for SDK enums. The package's own enums are frozen, because library evolution is off, so exhaustive switches cost nothing. A `default:` in a switch over `HubLink.Outcome` or `HookEvent` would let a new case compile and do nothing.

```swift
// Do
switch outcome {
case .delivered: showToast("Sent")
case .noHub, .unreachable: showToast("Saved. It goes when the Mac can be reached.")
case .refused, .interrupted: showToast("Saved. Redline tries again later.")
}

// Don't
switch outcome {
case .delivered: showToast("Sent")
default: showToast("Saved")  // A new Outcome compiles and is never explained.
}
```

**Check:** `grep -rn 'default:' Sources`. Each switches over a `String`, an `Int`, a tuple of those, or an SDK enum, in which case it is `@unknown default`. A `default:` over strings that may come from a newer peer carries a comment saying so.

**Source:** <https://github.com/swiftlang/swift-evolution/blob/main/proposals/0192-non-exhaustive-enums.md>

### E5. More than two meanings means an enum

**Level:** must

**Rule:** Model a state with more than two meanings as an enum, not as `Bool?` or as a `Bool` whose `false` covers several cases.

**Why:** At the call site, `installed == false` and `installed == nil` do not say which one means "phone unreachable". An enum names each case, and the compiler checks every switch over it. For wire fields kept as `Bool?` for compatibility (A12), decode the optional and expose a non-optional computed value. `HubLink.Outcome` is the pattern to copy.

```swift
// Do
enum Installation {
    case installed
    case notInstalled
    case unreachable
}
func installation(of bundleID: String, on udid: String) -> Installation

var acceptsUploads: Bool { uploads ?? true }  // Wire field kept; meaning made explicit.

// Don't
/// Whether an app is installed on the phone; nil when the phone can't be reached.
func isInstalled(_ bundleID: String, on udid: String) -> Bool?
```

**Check:** `grep -rn 'Bool?' Sources` finds only fields decoded from older data. A Bool-returning function whose doc lists more than one reason for false is a finding.

**Source:** <https://www.swift.org/documentation/api-design-guidelines/#clarity-at-the-point-of-use>

### E6. Structs by default; every class is final

**Level:** should

**Rule:** Use a struct unless you need identity, shared mutable state or a UIKit or AppKit subclass, mark every class `final`, and give each new class a one-line reason it is not a struct.

**Why:** Apple recommends structures by default. Redline follows this: `ReportStore`, `HubPaths` and `Devicectl` are structs, and every class is `final`.

```swift
// Do
struct ReportStore: Sendable { let root: URL }

/// A class because every connection shares one listener and its state.
final class HubListener: Sendable { ... }

// Don't
class ReportStore { var root: URL }  // No identity needed; not final.
```

**Check:** `grep -rnE '^\s*(private |fileprivate )?class ' Sources` finds nothing (every class starts with `final`).

**Source:** <https://developer.apple.com/documentation/swift/choosing-between-structures-and-classes>

### E7. Computed properties are cheap and have no side effects

**Level:** must

**Rule:** Make each computed property cheap and free of side effects, and when it reads files, decodes data, starts a process or scans a collection of unknown size, turn it into a method so the cost is visible, store the value and refresh it, or document its cost.

**Why:** Readers assume a property does no significant work, and SwiftUI reads properties freely (U1). A value that is computed rather than stored also cannot tell `@Observable` when it changes. That is why `DebugSession` stores `hubAddress` and refreshes it at set points, and why the Mac tool's disk checks are functions such as `isClaudeAppInstalled()`.

```swift
// Do
/// The hub's address, read when Redline starts and after each send.
private(set) var hubAddress: HubLink.Address?
var canPickDestination: Bool { hubAddress != nil }

func refreshHubAddress() { hubAddress = store.hubAddress() }

// Don't
var canPickDestination: Bool { store.hubAddress() != nil }  // Disk read and decode on every access.
```

**Check:** Open the body of each computed `var`. `Data(contentsOf:)`, `FileManager`, `Process`, decoding, or a loop over data of unknown size is a finding unless the doc comment states the cost. Check properties read from SwiftUI `body` first.

**Source:** <https://www.swift.org/documentation/api-design-guidelines/#document-computed-property-complexity>

### E8. Exit early with `guard`

**Level:** should

**Rule:** Check preconditions with `guard` at the top of a scope so the main path stays at the left margin, use the shorthand `guard let value`, and when a guard spans several lines, put `else` on its own line aligned with `guard`.

**Why:** All the guides agree. SE-0345 replaced `guard let value = value`. `guard let element = selected, let screenshot else { return }` in `DebugSession` is the model.

```swift
// Do
guard let element = selected, let screenshot else { return }

guard let reply = connection.response(to: hello),
    let client = reply["result"] as? [String: Any]
else { return .failed("The Codex app didn't answer") }

// Don't
if let element = selected {
    if let screenshot = screenshot {
        // Main work two levels deep.
    }
}
```

**Check:** Turn on swift-format `UseEarlyExits`. In review, flag more than two levels of nested `if let`, and any `guard let x = x`.

**Source:** <https://google.github.io/swift/#guards-for-early-exits>; <https://github.com/airbnb/swift#guards-at-top>; <https://github.com/swiftlang/swift-evolution/blob/main/proposals/0345-if-let-shorthand.md>

### E9. `for`-`in` for side effects; purpose-built algorithms for queries

**Level:** should

**Rule:** Use a `for`-`in` loop instead of `forEach` for side effects (passing a function reference to `forEach` is fine), and use `isEmpty`, `contains(where:)`, `first(where:)`, `count(where:)`, `min()` and `max()` instead of building intermediate arrays.

**Why:** A loop supports `break` and `continue` and reads the same to every Swift developer. The purpose-built calls stop early and allocate nothing. swift-format's `ReplaceForEachWithForLoop` rule is on by default.

```swift
// Do
for link in state.withLock({ Array($0.links.values) }) {
    link.phoneWoke()
}
let waiting = reports.count(where: \.isWaiting)

// Don't
lock.withLock { links.values }.forEach { $0.phoneWoke() }
let waiting = reports.filter { $0.isWaiting }.count
```

**Check:** swift-format reports no `ReplaceForEachWithForLoop` findings. `grep -rnE 'filter \{[^}]*\}\.(count|first|isEmpty)|sorted\(\)\.first' Sources` is empty.

**Source:** <https://github.com/airbnb/swift#prefer-for-loop-over-forEach>; <https://github.com/airbnb/swift#count-where>

### E10. One modern Foundation API per job

**Level:** should

**Rule:** Build file URLs with `URL(filePath:)`, `URL.homeDirectory` and `appending(path:)` rather than by joining path strings, write the current date as `.now`, use the standard library's `replacing(_:with:)`, and use one form for each job across the package.

**Why:** When the code uses two APIs for one job, readers wonder whether the difference matters. The modern URL APIs arrived in iOS 16 and macOS 13, below the package minimums. The package uses `appending(path:)` throughout. For dates, see [Decisions](#decisions).

```swift
// Do
let sessions = URL.homeDirectory.appending(path: ".claude/sessions", directoryHint: .isDirectory)
let exists = FileManager.default.fileExists(atPath: sessions.path(percentEncoded: false))
let record = Record(registeredAt: .now)

// Don't
let exists = FileManager.default.fileExists(atPath: NSHomeDirectory() + "/.claude/sessions")
let folderURL = URL(fileURLWithPath: folder)
let record = Record(registeredAt: Date())
```

**Check:** `grep -rnE 'fileURLWithPath|NSHomeDirectory\(\) \+|replacingOccurrences|Date\(\)' Sources | wc -l` must not grow, and new code uses the modern form.

**Source:** <https://github.com/airbnb/swift#prefer-swift-string-api>; <https://developer.apple.com/documentation/foundation/url/init(filepath:directoryhint:)>; <https://developer.apple.com/documentation/foundation/url/homedirectory>

### E11. Logging goes through one path per target

**Level:** should

**Rule:** In the kit, log only through `os.Logger` with one reverse-DNS subsystem constant, a category per area and privacy annotations on paths and device names, never `print`; in the Mac tool, print command output with `print`, send errors through one `printError` helper, and write the hub's file log through one serial queue and one open handle with a size cap.

**Why:** The unified log filters, routes and stores messages cheaply. A bare `"Redline"` subsystem would be hard to filter in Console when the kit is inside several host apps, so the kit's `Log` enum uses `io.github.mericksters13.redline` with a category per area. The Mac tool writes to standard error through `printError`, and the hub writes `hub.log` through one handle on its writer queue.

```swift
// Do
enum Log {
    static let subsystem = "io.github.mericksters13.redline"
}
private let logger = Logger(subsystem: Log.subsystem, category: "session")
logger.error("Couldn't read the draft: \(error.localizedDescription, privacy: .public)")

/// Writes a line for the user to standard error.
func printError(_ message: String) {
    FileHandle.standardError.write(Data((message + "\n").utf8))
}

// Don't
Logger(subsystem: "Redline", category: "session")
FileHandle.standardError.write(Data("Couldn't register the chat: \(error)\n".utf8))  // Fifth copy.
if let handle = try? FileHandle(forWritingTo: paths.log) { ... }                      // Opened for every line.
```

**Check:** `grep -rn 'print(' Sources/Redline` is empty. `grep -rn 'FileHandle.standardError.write' Sources/RedlineTool` finds only the helper. No `FileHandle(forWritingTo:)` runs once per message.

**Source:** <https://developer.apple.com/documentation/os/generating-log-messages-from-your-code>; <https://developer.apple.com/documentation/os/logger/init(subsystem:category:)>; <https://github.com/airbnb/swift#no-direct-standard-out-logs>

---

## S. Style and consistency

### S1. One formatter, checked in, enforced in CI

**Level:** should

**Rule:** Format with swift-format using a `.swift-format` file at the repo root, and fail CI when `swift format lint --strict` fails.

**Why:** Only a tool keeps the mechanics the same for every contributor. swift-format ships with the toolchain, so it adds no dependency. The checked-in `.swift-format` is the toolchain's default configuration (`swift format dump-configuration`) with these values set. The two trailing-comma values are the defaults, kept explicit for T5:

```json
{
  "indentation": { "spaces": 4 },
  "lineLength": 120,
  "indentConditionalCompilationBlocks": false,
  "lineBreakBeforeEachArgument": true,
  "multiElementCollectionTrailingCommas": true,
  "multilineTrailingCommaBehavior": "keptAsWritten",
  "rules": {
    "AllPublicDeclarationsHaveDocumentation": true,
    "BeginDocumentationCommentWithOneLineSummary": true,
    "ValidateDocumentationComments": true,
    "NeverForceUnwrap": true,
    "NeverUseForceTry": true,
    "UseEarlyExits": true
  }
}
```

Run `swift format --in-place --recursive Sources Tests scripts Package.swift` before you commit.

```text
Don't: leave formatting to each contributor's Xcode settings and argue about spacing in review.
```

**Check:** `.swift-format` exists. CI runs `swift format lint --strict --recursive --parallel Sources Tests scripts Package.swift` and it exits 0. A pull request that changes `.swift-format` states why.

**Source:** <https://github.com/swiftlang/swift-format#included-in-the-swift-toolchain>; <https://github.com/swiftlang/swift-format/blob/main/Documentation/Configuration.md>

### S2. Wrap at 120 columns

**Level:** should

**Rule:** Keep lines within 120 columns, and when a call or declaration does not fit, put each argument or parameter on its own line with the closing parenthesis on its own line, or pull a long expression into a named local.

**Why:** Readers of a public SDK see the code first in GitHub diffs, where long lines scroll sideways. swift-format wraps code at 120 columns but does not break string literals, so a long message needs a hand split or a named local.

```swift
// Do
let target = CGRect(
    x: point.x - size.width / 2,
    y: point.y - size.height / 2,
    width: size.width,
    height: size.height
)
view.zoom(to: target, animated: true)

// Don't
view.zoom(to: CGRect(x: point.x - size.width / 2, y: point.y - size.height / 2, width: size.width, height: size.height), animated: true)
```

**Check:** swift-format reports no `LineLength` findings. Quick look: `awk 'length > 120 && !/^ *\/\//' Sources/*/*.swift Tests/*/*.swift`.

**Source:** <https://google.github.io/swift/#column-limit>; <https://github.com/airbnb/swift#column-width>

### S3. One statement and one stored property per line

**Level:** should

**Rule:** Put one statement and one stored property declaration on each line, with no semicolons and no `let a = ..., b = ...`.

**Why:** Packed declarations hide properties from diffs, blame and doc comments. All the guides agree, and swift-format checks both by default.

```swift
// Do
struct Hardware: Decodable {
    var udid: String?
    var platform: String?
}

let lhs = Array(a.utf8)
let rhs = Array(b.utf8)

// Don't
struct Hardware: Decodable { var udid: String?; var platform: String? }
let x = Array(a.utf8), y = Array(b.utf8)
```

**Check:** swift-format `DoNotUseSemicolons` and `OneVariableDeclarationPerLine` report nothing.

**Source:** <https://google.github.io/swift/#one-statement-per-line>; <https://github.com/airbnb/swift#no-semicolons>

### S4. One-line blocks only for one short statement

**Level:** should

**Rule:** Let a block share a line with its condition only when it holds one simple statement and the whole line fits, and wrap the body when the condition is compound or the body does real work.

**Why:** Google allows one-line blocks and Airbnb forbids them. Short exits such as `guard let screenshot else { return }` read well and the code relies on them. A lock, a cache-age check and an early return on one 130-character line do not.

```swift
// Do
guard let screenshot else { return }
var inbox: URL { root.appending(path: "inbox", directoryHint: .isDirectory) }

if let entry = known.withLock({ $0[folder] }),
    Date.now.timeIntervalSince(entry.at) < Self.keepFor
{
    return entry.ids
}

// Don't
if let entry = lock.withLock({ known[folder] }), Date().timeIntervalSince(entry.at) < Self.keepFor { return entry.ids }
```

**Check:** In review, reject one-line blocks whose condition has `&&` or a comma list, or whose body makes more than one call. The line-length lint catches the rest.

**Source:** <https://google.github.io/swift/#one-statement-per-line>; <https://github.com/airbnb/swift#wrap-if-statement-bodies>

### S5. `self.` only where it is needed

**Level:** should

**Rule:** Write `self.` only where the compiler requires it or a local name shadows a member, and in `[weak self]` closures unwrap with `guard let self` and then use implicit self.

**Why:** Extra `self.` hides the places where it really disambiguates. SE-0269 allows implicit self in escaping closures for value types, which covers every SwiftUI view, and SE-0365 allows it after `guard let self`.

```swift
// Do
queue.asyncAfter(deadline: .now() + delay) { [weak self] in
    guard let self, let retryAt, Date.now >= retryAt.addingTimeInterval(-1) else { return }
    giveAddress()
}

// Don't
queue.asyncAfter(deadline: .now() + delay) { [weak self] in
    guard let self, let retryAt = self.retryAt, Date() >= retryAt.addingTimeInterval(-1) else { return }
    self.giveAddress()
}
```

**Check:** After each `guard let self`, look for `self.` on the following lines. Every remaining `self.` is an initializer assignment, resolves a shadowed name, or is required.

**Source:** <https://github.com/airbnb/swift#omit-self>; <https://github.com/swiftlang/swift-evolution/blob/main/proposals/0365-implicit-self-weak-capture.md>; <https://github.com/swiftlang/swift-evolution/blob/main/proposals/0269-implicit-self-explicit-capture.md>

### S6. The strictest access level, written on each declaration

**Level:** should

**Rule:** Use the strictest access level that works, prefer `private` to `fileprivate`, leave out `internal`, make a type used in only one file `private`, and write the access level on each declaration rather than on an extension.

**Why:** Narrow access keeps the module's internal surface readable and makes dead code obvious. A3 covers the public case. swift-format checks extensions and file-scope privacy by default.

```swift
// Do
private final class FolderApps: Sendable { ... }  // Used only in ChatDirectory.swift.

// Don't
internal final class FolderApps: @unchecked Sendable { ... }
fileprivate func helper() { ... }  // private works at file scope.
```

**Check:** swift-format `NoAccessLevelOnExtensionDeclaration` and `FileScopedDeclarationPrivacy` report nothing. `grep -rnE '^(public|internal|private|fileprivate) extension|\binternal ' Sources` is empty.

**Source:** <https://google.github.io/swift/#access-levels>; <https://github.com/airbnb/swift#limit-access-control>; <https://github.com/airbnb/swift#omit-internal-keyword>

### S7. Comments say why, in `///` and `//` only

**Level:** should

**Rule:** Write doc comments with `///` and other comments with `//`, never block comments; give internal types and non-obvious internal members a short summary; explain why rather than what; and add no file header comments.

**Why:** swift-format's `NoBlockComments` and `UseTripleSlashForDocumentationComments` rules are on by default. A comment that repeats the code goes stale without adding anything. Plain language and no emoji apply here too (AGENTS.md).

```swift
// Do
/// The chats a report from this app can go to.
// Retry once: devicectl drops the first call after the phone wakes.

// Don't
/* Abstract: Chat list */
// Calls background with SceneHook.
```

**Check:** `grep -rn '/\*' Sources` is empty. Comments that describe what the next line does are flagged in review.

**Source:** <https://google.github.io/swift/#general-format>; <https://github.com/airbnb/swift#single-line-comments>; <https://github.com/kodecocodes/swift-style-guide#comments>; `AGENTS.md`

### S8. Files hold one primary type and stay readable

**Level:** should

**Rule:** Name each file after its primary type, keep only small helpers that serve that type in the same file, move large features into `Type+Feature.swift` extension files, and split a type that needs more than about six MARK sections.

**Why:** A first-time contributor cannot find their way around a 1,300-line file. Stored properties must stay in the main declaration, and members used across the new files can no longer be `private`, so split where little private state crosses. This only moves code, so it passes A10.

```text
Do:
Sources/RedlineTool/Hub.swift               the hub
Sources/RedlineTool/HubPaths.swift          where the hub keeps its files
Sources/RedlineTool/HubStatus.swift         what the hub reports to the panel
Sources/RedlineTool/Handoff+Opening.swift   one feature of Handoff

Don't:
One Hub.swift that holds HubPaths, ReportSource, HubStatus and Hub.
One 1,300-line file with 13 MARK sections.
```

`DebugSession.swift` is still well over this size. Split it where little private state crosses, for example by making capture handling its own type first.

**Check:** Every file name equals its primary type or `Type+Feature`. Flag files over about 400 lines or with more than about six MARK sections: `wc -l Sources/*/*.swift | sort -n | tail`.

**Source:** <https://google.github.io/swift/#file-names>; <https://github.com/airbnb/swift#marks-within-types>; <https://github.com/apple/sample-backyard-birds>

### S9. MARK by feature; extensions organized the same way everywhere

**Level:** should

**Rule:** Group members under `// MARK: - Feature` headings, put a `// MARK: - ProtocolName` before each extension that adds a conformance, add one conformance per extension, and put helpers on standard library or Foundation types in one internal file per type named `Type+Redline.swift`.

**Why:** Mixing feature headings with access-level headings like `Private` or catch-alls like `Helpers` says nothing about the content. A helper on `String` is visible across the whole module, so it belongs in a file a reader can find.

```swift
// Do
// MARK: - Delivery

func deliver(_ report: Report) { ... }

// MARK: - Equatable

extension ReportSource: Equatable { ... }

// String+Redline.swift
extension String {
    /// The string, or nil when it is empty.
    var nonEmpty: String? { isEmpty ? nil : self }
}

// Don't
// MARK: - Helpers
// MARK: - Private
// ElementSelection.swift, after the selection logic:
extension String { var nonEmpty: String? { isEmpty ? nil : self } }
```

**Check:** `grep -rnE 'MARK: - (Private|Helpers|Misc|Other|Utilities)' Sources` is empty. `grep -rnE '^extension (String|Array|Dictionary|CGRect|CGPoint|CGSize|URL|Data)\b' Sources` hits only files named for that type.

**Source:** <https://google.github.io/swift/#type-variable-and-function-declarations>; <https://github.com/kodecocodes/swift-style-guide#protocol-conformance>; <https://docs.swift.org/swift-book/documentation/the-swift-programming-language/protocols/#Adding-Protocol-Conformance-with-an-Extension>

### S10. Trailing closures

**Level:** should

**Rule:** Use trailing closure syntax for a single final closure without empty `()`, never mix a labeled closure argument with a trailing one, and for APIs designed for several trailing closures (`Button { } label: { }`, `onGeometryChange`) use the trailing form with each closure on its own lines.

**Why:** See [Decisions](#decisions). swift-format's `OnlyOneTrailingClosureArgument` and `NoEmptyTrailingClosureParentheses` are on by default.

```swift
// Do
.onGeometryChange(for: CGRect.self) { proxy in
    proxy.frame(in: .global)
} action: { frame in
    session.setTouchableFrame(frame.insetBy(dx: -24, dy: -24), for: "suggestion")
}

// Don't
.onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { session.setTouchableFrame($0.insetBy(dx: -24, dy: -24), for: "suggestion") }
DispatchQueue.main.async() { ... }
```

**Check:** swift-format reports nothing for those two rules. In review, flag any call with two closures on one line.

**Source:** <https://github.com/swiftlang/swift-evolution/blob/main/proposals/0279-multiple-trailing-closures.md>; <https://github.com/nicklockwood/SwiftFormat/blob/main/Rules.md#trailingClosures>

### S11. No nested ternaries

**Level:** should

**Rule:** Use a ternary only for a short two-way choice inside a larger expression, and use an `if` or `switch` expression, usually in a small computed property, for three or more cases.

**Why:** Nested ternaries are hard to read and grow long lines. Since SE-0380, `if` and `switch` work as expressions, so there is no reason to chain ternaries.

```swift
// Do
private var noteCountTitle: String {
    switch count {
    case 0: "Tap an element"
    case 1: "1 note"
    default: "\(count) notes"
    }
}

// Don't
Text(count == 0 ? "Tap an element" : count == 1 ? "1 note" : "\(count) notes")
```

**Check:** `grep -nE '\?[^:?]+:[^?]+\?[^:]+:' Sources/*/*.swift` catches most nested ternaries.

**Source:** <https://github.com/airbnb/swift#prefer-if-expressions-over-ternary-operators>; <https://github.com/swiftlang/swift-evolution/blob/main/proposals/0380-if-switch-expressions.md>

### S12. Let the right-hand side supply the type

**Level:** should

**Rule:** Write a type annotation only to choose a different type or to type an empty literal, use the shorthand `[T]`, `[K: V]` and `T?`, prefer `let`, and name constants as lowerCamelCase `static let` members with no `k` prefix and without repeating the type name.

**Why:** This is what the code does (see [Decisions](#decisions)). swift-format checks shorthand types and repeated type names by default.

```swift
// Do
static let firstLookMargin: TimeInterval = 120
let store = ReportStore(root: root)
var state: [String: SourceState] = [:]
static let standard = HubPaths(root: ...)

// Don't
static let kFirstLookMargin = 120.0
let store: ReportStore = ReportStore(root: root)
var state = Dictionary<String, SourceState>()
static let standardHubPaths = HubPaths(root: ...)
```

**Check:** swift-format `UseShorthandTypeNames` and `DontRepeatTypeInStaticProperties` report nothing.

**Source:** <https://google.github.io/swift/#types-with-shorthand-names>; <https://github.com/airbnb/swift#infer-property-types>

### S13. Function names say whether they change anything

**Level:** must

**Rule:** Name a function that writes state, files or the network, or starts a process, with an imperative verb, name a function that only answers a question with a noun phrase, and never hide a write inside a noun-named function.

**Why:** From the call site, a reader cannot tell which functions change state unless the names say so. A name like `toCopy(...)` reads like a query. When such a function also starts tracking a source and saves state, split it, as the hub does with `startTrackingIfNeeded` and `reportIDsToCopy`. A function named `json(_:)` that starts a process hides the same kind of cost.

```swift
// Do
/// Starts tracking a source the first time it is seen, so old reports aren't delivered as new.
func startTracking(device: String, bundleID: String)
/// The reports from one app on one device still to copy.
func reportIDsToCopy(device: String, bundleID: String, finished: [FinishedReport]) -> [String]
static func fileURL(in paths: HubPaths) -> URL

// Don't
func toCopy(device: String, bundleID: String, finished: [FinishedReport]) -> [String]  // Also saves state.
private func json<T: Decodable>(_ arguments: [String]) -> T?                          // Starts a process.
```

**Check:** For each function that writes, sends or launches, the base name is a verb. Flag noun-named functions that contain `save`, `write`, `Process`, `send` or changes to stored state.

**Source:** <https://www.swift.org/documentation/api-design-guidelines/#name-according-to-side-effects>

### S14. `-ed` and `-ing` names return a changed copy

**Level:** should

**Rule:** Use an `-ed` or `-ing` name only for a function that returns a changed copy of its input or of `self`, and name queries as noun phrases and event handlers as `somethingDidChange`.

**Why:** Readers expect `sorted()` beside `sort()`. `AgentSettings.adding(_:to:executable:)` and `FloatingButtonPlacement.snapped(_:within:)` follow the pattern. `settled(...)` for a function that returns IDs, or `changed(_:)` for a callback, does not; in the hub those are `settledReportIDs` and `filesDidChange(at:)`.

```swift
// Do
static func adding(_ agent: Agent, to settings: [String: Any], executable: String) -> [String: Any]
func settledReportIDs(device: String, bundleID: String, finished: [FinishedReport]) -> [String]
private func filesDidChange(at paths: [String])

// Don't
func settled(device: String, bundleID: String, finished: [FinishedReport]) -> [String]
private func changed(_ paths: [String])
```

**Check:** `grep -rnoE 'func [a-zA-Z]+(ed|ing)\(' Sources`. Each hit returns a changed copy.

**Source:** <https://www.swift.org/documentation/api-design-guidelines/#name-according-to-side-effects>

### S15. Booleans read as statements

**Level:** should

**Rule:** Start Boolean properties, Bool-returning methods and Bool parameter labels with `is`, `has`, `can` or `should`, or use a third-person verb such as `showsDetails`, use one form per idea, and make a Bool parameter's label say what `true` means.

**Why:** `x.isEmpty` reads as a statement, while `x.sameWorktree` does not. Use one form for the same kind of state, as `isNoteFocused` and `isEditingNote` do for focus. Good existing names to copy: `isSameView(as:)`, `canStepUp`, `hasAccess`, `isContainer`. For Codable wire types, pair a rename with `CodingKeys` (A12).

```swift
// Do
@FocusState private var isNoteFocused: Bool
var isSameWorktree: Bool
func isSameChoice(as other: Destination?) -> Bool
private func discover(rescanningForNewApps: Bool)

// Don't
@FocusState private var noteFocused: Bool
var sameWorktree: Bool
func sameChoice(as other: Destination?) -> Bool
private func discover(rediscover: Bool)
```

**Check:** `grep -rnE '(var|let) [a-zA-Z]+: Bool|-> Bool' Sources`. Read each as `x.name`: it must be a yes-or-no statement. Read each Bool argument at its call site.

**Source:** <https://www.swift.org/documentation/api-design-guidelines/#boolean-assertions>; <https://github.com/airbnb/swift#bool-names>

### S16. Label arguments, especially weakly typed ones

**Level:** should

**Rule:** Label every argument after the first unless the arguments are interchangeable, put a noun that names the role before weakly typed values such as `String`, `[String]`, `Any` or `Int`, and leave out the first label only when the call reads as a phrase.

**Why:** A call like `git(folder, ["fetch"])` does not say what each value is, and swapping two strings still compiles. Read new call sites aloud.

```swift
// Do
private static func git(_ arguments: [String], in folder: String, timeout: TimeInterval = 60) -> String?
static func output(for event: HookEvent, text: String?) -> [String: Any]?
git(["fetch", "origin"], in: folder)

// Don't
private static func git(_ folder: String, _ arguments: [String], timeout: TimeInterval = 60) -> String?
output(event, text)
```

**Check:** `grep -rnE 'func [a-zA-Z]+\(_ [a-zA-Z]+: [^,)]+, _ ' Sources` finds functions with two or more unlabeled parameters. Each hit has interchangeable arguments.

**Source:** <https://www.swift.org/documentation/api-design-guidelines/#weak-type-information>; <https://www.swift.org/documentation/api-design-guidelines/#omit-first-argument-if-partial-phrase>

### S17. Name closure parameters and tuple members

**Level:** should

**Rule:** Name each parameter of a closure type in a signature, label every tuple in a return type, and turn a tuple into a struct once it is stored, passed between types, or has more than three fields.

**Why:** Names explain what values mean and can be referenced from doc comments. Most of the code already does this (`beginReport(date:) -> (id:folder:draft:)`). A parameter typed `(URL) -> Bool` leaves the reader guessing what the URL is.

```swift
// Do
func receive(_ source: ReportSource, copy: (_ destination: URL) throws -> Void) throws
private func notes(_ list: [Report.Item], jump: ((_ itemNumber: Int) -> Void)?) -> some View

// Don't
func receive(_ source: ReportSource, copy: (URL) -> Bool) -> Bool
private func notes(_ list: [Report.Item], jump: ((Int) -> Void)?) -> some View
```

**Check:** Every closure-typed parameter names its own parameters. Every tuple in a return type has labels. A tuple stored in a property or used as a dictionary value is a struct.

**Source:** <https://www.swift.org/documentation/api-design-guidelines/#label-closure-parameters>

### S18. Case and acronym conventions

**Level:** should

**Rule:** Name types and protocols in UpperCamelCase and everything else in lowerCamelCase, keep acronyms in one case (`bundleID`, `udid`, `hubURL`), and start factory methods with `make`.

**Why:** These are the Swift API Design Guidelines conventions. JSON keys that mirror other tools' protocols, such as `requestId` in `CodexApp.swift`, are string data rather than Swift names, so they are exempt.

```swift
// Do
let bundleID: String
func makeConnection(to address: Address) -> NWConnection

// Don't
let bundleId: String
func createConnection(to address: Address) -> NWConnection
```

**Check:** swift-format `AlwaysUseLowerCamelCase` and `TypeNamesShouldBeCapitalized` report nothing. `grep -rnE '[a-z](Id|Url|Json)\b' Sources` hits only string keys and SDK names.

**Source:** <https://www.swift.org/documentation/api-design-guidelines/#conventions>; <https://github.com/airbnb/swift#capitalize-acronyms>

---

## T. Tests and package hygiene

### T1. Swift Testing, written the same way everywhere

**Level:** must

**Rule:** Write functional tests with Swift Testing in struct suites without a bare `@Suite`, name tests as lowerCamelCase sentences with no `test` prefix or display string, mark tests that can fail with an error as `throws`, unwrap with `try #require`, and use no `!`, `try!` or raw-identifier names. XCTest is allowed only for `measure(metrics:)` performance tests in files named `*PerformanceTests.swift`.

**Why:** A `try!` crash ends the whole test run instead of failing one test. Any type that contains tests is already a suite. Raw-identifier names need Swift 6.2, above the compiler floor (T5). The existing tests already use struct suites and sentence names such as `snapsToTheNearestSideEdge`. Swift Testing has no performance API, which is the only reason XCTest remains.

```swift
// Do
@Test func stopHookLetsTheChatEnd() throws {
    let output = try #require(AgentHooks.output(for: .claude, event: .stop, text: "done"))
    #expect(try json(output) == expected)
}

// Don't
String(decoding: try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), as: UTF8.self)

@Suite struct HubTests {
    @Test("Stop hook") func testStopHook() { ... }
}
```

**Check:** `grep -rnE 'try!|func test[A-Z]|@Test\("' Tests` is empty outside `*PerformanceTests.swift`. `import XCTest` appears only in those files. Test files are named `<Type>Tests.swift`.

**Source:** <https://developer.apple.com/documentation/testing/definingtests>; <https://github.com/airbnb/swift#prefer-swift-testing>; <https://github.com/airbnb/swift#avoid-force-unwrap-in-tests>; <https://github.com/swiftlang/swift-evolution/blob/main/proposals/0451-escaped-identifiers.md>

### T2. Tests wait for events, with a timeout

**Level:** must

**Rule:** Make tests wait for the event they expect, through a continuation, `confirmation` or an async sequence, with a timeout on every wait, instead of sleeping in a polling loop or blocking a thread, and run blocking code under test on a Dispatch queue.

**Why:** Swift Testing runs tests in parallel inside task groups, so even a synchronous test runs on the cooperative pool. A sleep or a semaphore wait there blocks a pool thread and slows or deadlocks other tests (C1, C2). Sleep-based polling also makes tests depend on timing.

```swift
// Do
/// Runs blocking code under test on a Dispatch queue so it does not hold a cooperative thread.
func offPool<T: Sendable>(_ body: @escaping @Sendable () -> T) async -> T {
    await withCheckedContinuation { continuation in
        DispatchQueue.global().async { continuation.resume(returning: body()) }
    }
}

@Test func waitingReturnsWhenAReportArrives() async throws {
    let chat = try makeSession()
    async let arrived = offPool { chat.waitForReport(timeout: 5, waiter: ChatSession.Waiter()) }
    try writeInboxReport("20261003-230000")
    #expect(await arrived)
}

// Don't
let deadline = Date().addingTimeInterval(2)
while !answered(), Date() < deadline { Thread.sleep(forTimeInterval: 0.02) }
```

**Check:** `grep -rnE 'Thread\.sleep|usleep|\.wait\(|try\? await Task\.sleep' Tests`. Each poll loop has a comment saying why the code under test offers no event. CI runs `swift test --sanitize=thread`.

**Source:** <https://developer.apple.com/documentation/testing/parallelization>; <https://developer.apple.com/documentation/testing/testing-asynchronous-code>

### T3. Hot paths have performance tests with realistic data

**Level:** should

**Rule:** Cover each hot path (reading the inbox for the panel, thumbnail loading, a large upload, composing a multi-screen report) with an XCTest `measure(metrics:)` test that uses a realistic fixture, such as a 500-report inbox, never an empty one.

**Why:** Most costs in this package appear only with real-sized data. Recorded measurements turn a regression into a failing test instead of a complaint from a user.

```swift
// Do (InboxPerformanceTests.swift)
func testPanelReadWithLargeInbox() throws {
    let paths = try makeFixtureInbox(reports: 500)
    measure(metrics: [XCTClockMetric(), XCTStorageMetric(), XCTMemoryMetric()]) {
        _ = HubWindowModel.readReports(paths: paths)
    }
}

// Don't
@Test func readReports() { #expect(HubWindowModel.readReports(paths: emptyPaths).isEmpty) }  // Proves nothing about cost.
```

**Check:** Each hot path named above has a measure test. Pull requests that touch one include its numbers (P15).

**Source:** <https://developer.apple.com/documentation/xcode/preventing-memory-use-regressions>

### T4. The Release product is verified

**Level:** must

**Rule:** Build the package in Debug and Release with `xcodebuild`, and confirm that the Release product contains no kit code, no private API name and no developer file path.

**Why:** The Debug-only promise (A1, A2, A4) is the main thing users rely on, and only a check of the actual binary proves it.

```sh
# Do
xcodebuild -scheme Redline -destination 'generic/platform=iOS Simulator' -derivedDataPath .build/xcode -configuration Debug build
xcodebuild -scheme Redline -destination 'generic/platform=iOS Simulator' -derivedDataPath .build/xcode -configuration Release build
! strings -a <Release product> | grep -q AXSSetAutomationEnabled
! strings -a <Release host app binary> | grep -q "$HOME"
```

```text
Don't: check only that the Debug build works, and trust #if for the rest.
```

**Check:** CI runs these commands, and the release checklist repeats them before each tag.

**Source:** `AGENTS.md` (Verification)

### T5. Respect the compiler floor set by the tools version

**Level:** must

**Rule:** Use no syntax or API newer than Swift 6.0 while `swift-tools-version` is 6.0, including trailing commas in argument and parameter lists, raw identifiers and `@concurrent`; test with the oldest supported Xcode in CI, or raise the tools version on purpose with a CHANGELOG entry; and do not add `swiftLanguageModes`.

**Why:** The tools version declares the minimum compiler that can use the package, and dependency resolution skips versions whose tools version is newer than the user's compiler. The maintainer builds with Swift 6.4, so newer syntax compiles locally and breaks Xcode 16.0 users. Tools version 6.0 already turns on the Swift 6 language mode for every target.

```swift
// Do
annotations.append(
    Annotation(
        id: id,
        createdAt: .now,
        note: note
    )
)

// Don't
annotations.append(
    Annotation(
        id: id,
        createdAt: .now,
        note: note,  // A trailing comma in an argument list needs Swift 6.1.
    )
)
@Test func `snaps to the nearest edge`() { }  // Needs Swift 6.2.
```

**Check:** CI builds and tests with the oldest supported Xcode, for example `DEVELOPER_DIR=/Applications/Xcode_16.0.app/Contents/Developer swift build`. swift-format keeps `multilineTrailingCommaBehavior` at `keptAsWritten`.

**Source:** <https://docs.swift.org/swiftpm/documentation/packagemanagerdocs/settingswifttoolsversion>; <https://github.com/swiftlang/swift-evolution/blob/main/proposals/0439-trailing-comma-lists.md>; <https://github.com/swiftlang/swift-evolution/blob/main/proposals/0451-escaped-identifiers.md>

### T6. `Package.swift` stays usable by other packages

**Level:** must

**Rule:** Use no `unsafeFlags`, make build switches only through conditional `.define` settings, keep products to what users import or run, comment every setting that is not obvious, and put strictness such as warnings-as-errors in the CI command rather than the manifest.

**Why:** Unsafe flags make a target's products ineligible for use by other packages, and Swift Package Index requires the manifest to load and the package to build. The current manifest is a good example: the Debug-only define and the platforms are both explained.

```swift
// Do
let debugOnly: [SwiftSetting] = [.define("REDLINE", .when(configuration: .debug))]
// CI: swift build -Xswiftc -warnings-as-errors && swift test

// Don't
.target(name: "Redline", swiftSettings: [.unsafeFlags(["-warnings-as-errors"])])
```

**Check:** `grep -n unsafeFlags Package.swift` is empty. `swift package dump-package` succeeds.

**Source:** <https://developer.apple.com/documentation/packagedescription/swiftsetting/unsafeflags(_:_:)>; <https://github.com/SwiftPackageIndex/PackageList>

### T7. Release basics before the first public tag

**Level:** must

**Rule:** Before tagging, add a `LICENSE` and a `CHANGELOG.md` in Keep a Changelog format with an Unreleased section, tag with three-part semantic versions such as `0.1.0`, stay on `0.y.z` until the public surface (the modifier, the `redline` commands, the MCP tools and the phone-to-Mac format) is stable, and have the README state requirements, installation with `.upToNextMinor(from:)`, the one-line setup, and that Release builds compile the kit out.

**Why:** Without a license, nobody may legally reuse the code. SwiftPM recognizes only full semantic version tags. Under 1.0, anything may change, and SwiftPM's `from:` accepts any version up to the next major, so `from: "0.1.0"` would pull in a breaking `0.2.0`.

```swift
// Do (README, while below 1.0)
.package(url: "https://github.com/mericksters13/agent-redline-ios.git", .upToNextMinor(from: "0.1.0"))

// Don't
// git tag v0.1  (SwiftPM ignores it)
.package(url: "https://github.com/mericksters13/agent-redline-ios.git", from: "0.1.0")  // Also accepts 0.2.0.
```

**Check:** `ls LICENSE* CHANGELOG.md` succeeds. `git tag` shows only tags matching `^[0-9]+\.[0-9]+\.[0-9]+$`. Every pull request that changes public behavior adds an entry under Unreleased.

**Source:** <https://docs.github.com/en/repositories/managing-your-repositorys-settings-and-features/customizing-your-repository/licensing-a-repository>; <https://docs.swift.org/swiftpm/documentation/packagemanagerdocs/releasingpublishingapackage>; <https://semver.org/>; <https://keepachangelog.com/en/1.1.0/>

### T8. One CI run checks everything in this guide that a machine can check

**Level:** should

**Rule:** Run every automated check in this guide in CI on each pull request: format lint, a warnings-as-errors build, `swift test`, the thread sanitizer, the Debug and Release `xcodebuild` builds with the binary checks, a documentation build, and a build on the oldest supported Xcode.

**Why:** Rules that are not checked drift. Until the repo has a CI configuration, run these commands before each pull request; [CONTRIBUTING.md](../CONTRIBUTING.md) lists them.

```sh
# Do
swift format lint --strict --recursive --parallel Sources Tests scripts Package.swift
swift build -Xswiftc -warnings-as-errors
swift test
swift test --sanitize=thread --filter RedlineToolTests
# plus T4 (Debug and Release, binary checks), A5 (docbuild), T5 (oldest Xcode)
```

```text
Don't: rely on reviewers to remember which commands to run.
```

**Check:** The CI configuration lists each command above, and a failure in any of them blocks merge.

**Source:** <https://google.github.io/swift/#compiler-warnings>; `AGENTS.md` (Verification)

---

## Quick scan

Run from the repo root for a first pass. Every hit still needs reading.

```sh
grep -L '^#if REDLINE' Sources/Redline/*.swift                         # A1: only Redline.swift
grep -rnE '\b(public|open) (func|var|let|struct|class|enum|extension)\b' Sources/Redline  # A3: one declaration
grep -rnE '@_[a-zA-Z]' Sources                                         # A9
grep -rnE 'waitUntilExit|readDataToEndOfFile|\.wait\(|Thread\.sleep|sqlite3_|\.sync \{' Sources  # C1, C2
grep -rn '@unchecked Sendable\|nonisolated(unsafe)' Sources | wc -l    # C4: not above 8
grep -rn 'NSLock\|MainActor.run\|Task.detached' Sources                # C5, C9, C11
grep -rn -A1 'try? await Task.sleep' Sources Tests                     # C15
grep -rnE 'ObservableObject|@Published|AnyView|GeometryReader' Sources # U3, U10, U11
grep -rn 'onTapGesture\|font(.system(size:' Sources                    # U14, U17
grep -rnE 'Formatter\(\)' Sources                                      # U6
grep -rn 'Process()' Sources                                           # P3: helper only
grep -rnE 'JSON(En|De)coder\(\)' Sources                               # P14: statics only
grep -rn 'try?' Sources                                                # E2: read each
grep -rnE 'try!|as! ' Sources Tests                                    # E3, T1
grep -rn 'default:' Sources                                            # E4
grep -rn 'Bool?' Sources                                               # E5
grep -rnE 'MARK: - (Private|Helpers)' Sources                          # S9
awk 'length > 120 && !/^ *\/\//' Sources/*/*.swift                     # S2: long string literals only
```
