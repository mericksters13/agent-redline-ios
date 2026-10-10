# Redline Demo

Redline Demo is an iOS app for trying Redline end to end: a recipe browser with `.redline()` on its root view, sample tabs to annotate and three planted UI bugs to find. It references the Redline package in this repository by local path (`../..`), so every build compiles the kit from your checkout.

The npm package doesn't include the demo. Clone the repository to get it.

| Tab | Screen | Built with |
|---|---|---|
| Recipes | A searchable list with a sort menu. Each row opens the recipe's detail view. | SwiftUI |
| Tonight | A recipe's detail view, which scrolls well past one screen: header, stats grid, Start cooking button, ingredients and method. | SwiftUI |
| Plan | A form with text fields, a date picker, a toggle, a picker and a Save button. | SwiftUI |
| UIKit | A shopping list built from `UILabel`, `UITextField`, `UISegmentedControl`, `UISwitch` and `UIButton`, in a `UIViewController` hosted with `UIViewControllerRepresentable`. | UIKit |
| Layout (Debug) | Fixed, flexible, nested, and default-padding samples for trying the captured component and constraint visualizer. | SwiftUI |

## Run it

1. **Install the Mac side**, so reports reach your session:

   ```sh
   npx agent-redline-ios
   ```

   [Install on the Mac](../../README.md#install-on-the-mac) covers the other install options and the steps the installer leaves to you.

2. **Open `RedlineDemo.xcodeproj`** in Xcode 26 or later and choose the RedlineDemo scheme. A simulator build needs no team. For a device build, select your team under Signing & Capabilities for the RedlineDemo target. If Xcode reports that the bundle ID `com.agentredline.demo` isn't available, change it there to one under your own prefix.
3. **Open a Claude Code or Codex session** in your clone. Redline reads the demo's bundle ID from `RedlineDemo.xcodeproj` when the session registers, so finish any bundle ID change first. A Codex session registers on your next message to it.
4. **Run the demo** on a device or simulator. Run builds the Debug configuration, the only one that includes the kit.

On a device, Redline finds a new install on its next scan, within 30 minutes. To scan now, click Quit in the menu bar panel and reopen `Redline.app`. The first report sent from an iPhone triggers the iOS local network prompt; allow it, or reports can't reach the Mac.

## What to try

- **Annotate and send.** Tap the floating Redline button, tap an element, write a note and tap Add note. Notes collect across tabs until you send them, so add a few on different screens, then open the notes tray and tap Send. The first time, pick your session in Send to.
- **Inspect padding and frame.** Open Layout in a Debug build, tap Redline, then a sample. The annotation form shows its captured component, red padding measurements, and frame size. Tap a measurement to include it in the note; use the layers icon for hierarchy and the Padding & frame chevron to collapse the preview. Layout inspection activates when the demo starts; no launch arguments are needed. [Supported behavior and research controls](LAYOUT-PROTOTYPE.md) describe the experimental runtime limits.
- **Read the identifiers.** Key elements have accessibility identifiers, such as `list.sort`, `detail.start`, `form.save` and `uikit.submit`, so a note in your session reads like `Start cooking (Button, detail.start): ...`.
- **Select an enclosing element.** After you tap a stat on the Tonight tab, the note card's path reads `detail.stats`, then the stat. Tap `detail.stats` to select the whole grid.
- **Pick UIKit views.** On the UIKit tab, annotate the text field, the segmented control, the switch and the Add to list button. Each note carries the view's label and identifier, as it does for SwiftUI elements.
- **Send a screenshot.** Take a screenshot in the build. A thumbnail appears beside the floating button; tap it to add a note and send it with its snapshot.
- **Find the planted bugs.** Three screens each have one visible UI bug. Report each one you find and ask your agent to fix it. The bugs stay in the repository on purpose, so keep those fixes in your clone.

## Planted bugs (spoilers)

<details>
<summary>Show the three planted bugs</summary>

1. **Recipes list: summaries are cut off.** Each row's summary has a fixed width of 150 points, so longer summaries are truncated even when the row has room for them. In `RecipeList.swift`, `RecipeRow`.
2. **Recipe detail: Start cooking sits right of center.** The button has a leading inset with no matching trailing one. Open any recipe, or the Tonight tab. In `RecipeDetail.swift`, `startButton`.
3. **UIKit tab: the hint under Item fades out in dark mode.** The hint uses a fixed dark gray instead of `.secondaryLabel`, so it reads in light mode but barely shows in dark mode. In `ShoppingListViewController.swift`, `addContent()`.

Each one is marked in code with a comment that starts "Planted bug for the demo".

</details>

## Regenerate the project

`RedlineDemo.xcodeproj` is generated from `project.yml` with [XcodeGen](https://github.com/yonaskolb/XcodeGen) 2.45 or later and committed, so running the demo doesn't need XcodeGen. To change the project, edit `project.yml` rather than the project in Xcode, then regenerate:

```sh
cd Examples/RedlineDemo
xcodegen generate
```

Commit `project.yml` and `RedlineDemo.xcodeproj` together. New Swift files in `RedlineDemo/` need a regeneration too.
